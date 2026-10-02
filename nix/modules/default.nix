{ config, lib, pkgs, ... }:

let
  cfg = config.services.kindling;
  packages = import ../packages.nix { inherit pkgs; };
  source = ../..;
  mtuScript = "${pkgs.bash}/bin/sh ${source}/overlay/usr/local/sbin/sparkos-mtu";
  checkScript = "${pkgs.bash}/bin/bash ${source}/overlay/usr/local/sbin/sparkos-mentatd-check";
  memory = "${packages.sparkMemory}/bin/spark-memory";
  routeReady = pkgs.writeShellScript "kindling-mentat-route" ''
    [ -n "''${MENTAT_NODE_IP:-}" ] || ${pkgs.iproute2}/bin/ip -4 route get 8.8.8.8 >/dev/null
  '';
  logo = pkgs.writeShellScriptBin "spark-logo" ''
    exec ${pkgs.python3}/bin/python3 ${source}/overlay/usr/local/bin/spark-logo "$@"
  '';
  console = pkgs.writeShellScript "kindling-console" ''
    export PATH=/run/opengl-driver/bin:$PATH
    exec ${pkgs.bash}/bin/bash ${source}/overlay/usr/local/bin/spark-console
  '';
in
{
  imports = [ ./dispram.nix ];

  options.services.kindling = {
    enable = lib.mkEnableOption "Kindling Spark host services on an existing NixOS GB10 installation";

    nodeEnvironmentFile = lib.mkOption {
      type = lib.types.str;
      default = "/etc/spark/node.env";
      description = "Absolute path to the mentatd environment file (including MENTAT_SECRET_FILE).";
    };
    agentEnvironmentFile = lib.mkOption {
      type = lib.types.str;
      default = "/etc/spark/agent.env";
      description = "Optional path to the spark-agent environment file.";
    };
    openFirewall = lib.mkEnableOption "the mentat and agent ports on all interfaces (trusted networks only)";
    console.enable = lib.mkEnableOption "the Kindling status screen on tty1 instead of a getty";
    watchdog.enable = lib.mkEnableOption "the Kindling hardware watchdog (can reset the machine)";
    connectxMtu = lib.mkOption {
      type = lib.types.int;
      default = 0;
      description = "ConnectX RoCE MTU; 0 keeps the configured interface MTU.";
    };
    ethernetMtu = lib.mkOption {
      type = lib.types.int;
      default = 0;
      description = "Exact MTU for non-ConnectX physical en* ports; 0 leaves it alone.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.elem cfg.connectxMtu [ 0 256 512 1024 2048 4096 ];
        message = "services.kindling.connectxMtu must be 0, 256, 512, 1024, 2048 or 4096.";
      }
      {
        assertion = cfg.ethernetMtu == 0 || (cfg.ethernetMtu >= 576 && cfg.ethernetMtu <= 9978);
        message = "services.kindling.ethernetMtu must be 0 or between 576 and 9978.";
      }
    ];

    # On 64K-page kernels, THP raises vm.min_free_kbytes to roughly 5% of RAM.
    # Match the Ubuntu image's choice without selecting the kernel ourselves.
    boot.kernelParams = lib.optional (config.hardware.dgx-spark.use64kKernel or false)
      "transparent_hugepage=never";

    # The Ubuntu image's GRUB, DGX bind mounts, uid migration, and trial timer are intentionally
    # not installed: the NixOS host owns its own boot loader, user database, and persistent state.
    environment.etc = {
      "kindling/version".text = builtins.readFile (source + "/VERSION");
      "spark-os-version".text = "NixOS ${config.system.nixos.version}\n";
    } // lib.optionalAttrs (cfg.connectxMtu != 0) {
      "kindling/connectx-mtu".text = "${toString cfg.connectxMtu}\n";
    } // lib.optionalAttrs (cfg.ethernetMtu != 0) {
      "kindling/ethernet-mtu".text = "${toString cfg.ethernetMtu}\n";
    };

    # NixOS owns accounts; unlike the Ubuntu image, never copy passwords/groups from DGX OS.
    users.groups.spark-agent = { };
    users.users.spark-agent = {
      isSystemUser = true;
      group = "spark-agent";
    };

    networking.firewall.allowedTCPPorts = lib.optionals cfg.openFirewall [ 6379 6380 8090 ];
    networking.firewall.allowedUDPPorts = lib.optionals cfg.openFirewall [ 6382 ];

    systemd.services.mentatd = {
      description = "Kindling mentat node daemon";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" "NetworkManager.service" ];
      unitConfig = {
        ConditionPathExists = cfg.nodeEnvironmentFile;
        StartLimitIntervalSec = 0;
      };
      path = [ pkgs.iproute2 ];
      serviceConfig = {
        EnvironmentFile = cfg.nodeEnvironmentFile;
        ExecStartPre = routeReady;
        ExecStart = "${packages.mentatd}/bin/mentatd daemon";
        Restart = "always";
        RestartSec = 2;
        RestartSteps = 10;
        RestartMaxDelaySec = 60;
      };
    };

    systemd.services.spark-agent = {
      description = "Kindling host status and MCP agent";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" "mentatd.service" ];
      path = with pkgs; [ coreutils iproute2 procps pciutils usbutils rdma-core python3 ];
      environment = {
        AGENT_LOG_DIR = "/var/log/spark";
        SPARK_MEMORY_PY = memory;
        PY_SPY = "${pkgs.py-spy}/bin/py-spy";
      };
      serviceConfig = {
        User = "spark-agent";
        Group = "spark-agent";
        EnvironmentFile = "-${cfg.agentEnvironmentFile}";
        ExecStart = "${packages.sparkAgent}/bin/spark-agent --port 8090";
        Restart = "always";
        RestartSec = 5;
        AmbientCapabilities = "CAP_SYS_PTRACE";
        CapabilityBoundingSet = "CAP_SYS_PTRACE";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
      };
    };

    systemd.services.spark-dmesg-snapshot = {
      description = "Snapshot host-only diagnostics for the Kindling agent";
      path = with pkgs; [ coreutils gnugrep gnused gawk procps systemd docker rdma-core iproute2 packages.sparkMemory ];
      environment = { SPARK_MEMORY_PY = memory; };
      serviceConfig = {
        Type = "oneshot";
        Nice = 10;
        IOSchedulingClass = "idle";
        ExecStart = "${pkgs.bash}/bin/sh ${source}/overlay/usr/local/bin/spark-log-snapshot.sh";
      };
    };
    systemd.timers.spark-dmesg-snapshot = {
      description = "Refresh Kindling agent diagnostics";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "30s";
        OnUnitActiveSec = "60s";
        Persistent = true;
      };
    };

    systemd.services.sparkos-mentatd-check = {
      description = "Restart unresponsive mentatd after a network change";
      after = [ "mentatd.service" ];
      path = with pkgs; [ systemd curl coreutils ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = checkScript;
      };
    };

    systemd.services.sparkos-mtu = lib.mkIf (cfg.connectxMtu != 0 || cfg.ethernetMtu != 0) {
      description = "Apply Kindling GB10 port MTUs";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      path = with pkgs; [ coreutils iproute2 ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = mtuScript;
      };
    };

    networking.networkmanager.dispatcherScripts = lib.mkIf config.networking.networkmanager.enable [
      {
        source = pkgs.writeShellScript "kindling-network-dispatcher" ''
          case "$2" in
            up|down|dhcp4-change|dhcp6-change|connectivity-change)
              ${pkgs.systemd}/bin/systemctl start --no-block sparkos-mentatd-check.service ;;
          esac
          case "$2" in
            up|reapply) ${lib.optionalString (cfg.connectxMtu != 0 || cfg.ethernetMtu != 0) ''exec ${mtuScript} "$1"''} ;;
          esac
        '';
        type = "basic";
      }
    ];

    systemd.services.spark-console = lib.mkIf cfg.console.enable {
      description = "Kindling cluster status on tty1";
      wantedBy = [ "getty.target" ];
      after = [ "systemd-user-sessions.service" "mentatd.service" ];
      conflicts = [ "getty@tty1.service" ];
      before = [ "getty.target" ];
      path = with pkgs; [ coreutils procps iproute2 curl jq gnused gawk gnugrep util-linux ncurses docker logo ];
      environment = {
        TERM = "linux";
        SPARK_LOGIN = "${pkgs.shadow}/bin/login";
        SPARK_LOGO_DIR = "${source}/overlay/usr/share/kindling";
      };
      serviceConfig = {
        ExecStart = console;
        StandardInput = "tty";
        StandardOutput = "tty";
        TTYPath = "/dev/tty1";
        TTYReset = true;
        TTYVHangup = true;
        TTYVTDisallocate = true;
        Restart = "always";
        RestartSec = 0;
        UtmpIdentifier = "tty1";
      };
    };
    systemd.services."getty@tty1".enable = lib.mkIf cfg.console.enable false;

    # Both systemd and spark-watchdog cannot own /dev/watchdog.
    systemd.settings.Manager.RuntimeWatchdogSec = lib.mkIf cfg.watchdog.enable "0";

    systemd.services.spark-watchdog = lib.mkIf cfg.watchdog.enable {
      description = "Pet the SBSA watchdog while the host can still fork";
      wantedBy = [ "multi-user.target" ];
      unitConfig.ConditionPathExists = "/dev/watchdog";
      environment = {
        WATCHDOG_TIMEOUT_S = "60";
        WATCHDOG_INTERVAL_S = "15";
        WATCHDOG_FAILURES = "4";
        WATCHDOG_PROBE_CMD = "${pkgs.coreutils}/bin/true";
      };
      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python3 ${source}/overlay/usr/local/bin/spark-watchdog.py";
        StateDirectory = "spark-watchdog";
        Restart = "on-failure";
        RestartPreventExitStatus = 3;
        KillSignal = "SIGTERM";
        TimeoutStopSec = 30;
      };
    };
  };
}
