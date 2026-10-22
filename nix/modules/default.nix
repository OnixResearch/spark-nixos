{ config, lib, pkgs, ... }:

let
  cfg = config.services.kindling;
  packages = import ../packages.nix { inherit pkgs; };
  # Units refer to single overlay files, so only those files are copied to the store. A copy of
  # the whole checkout would carry .git too, and any edit or fetch would restart the units.
  mtuScript = "${pkgs.bash}/bin/sh ${../../overlay/usr/local/sbin/sparkos-mtu}";
  mtuEnabled = cfg.connectxMtu != 0 || cfg.ethernetMtu != 0;
  checkScript = "${pkgs.bash}/bin/bash ${../../overlay/usr/local/sbin/sparkos-mentatd-check}";
  memory = "${packages.sparkMemory}/bin/spark-memory";
  routeReady = pkgs.writeShellScript "kindling-mentat-route" ''
    [ -n "''${MENTAT_NODE_IP:-}" ] || ${pkgs.iproute2}/bin/ip -4 route get 8.8.8.8 >/dev/null
  '';
  logo = pkgs.writeShellScriptBin "spark-logo" ''
    exec ${pkgs.python3}/bin/python3 ${../../overlay/usr/local/bin/spark-logo} "$@"
  '';
  # NixOS installs nvidia-smi in the driver's bin output, which /run/opengl-driver leaves out.
  # A unit's PATH has only its path packages and a few defaults, so each unit that runs it lists this.
  nvidiaBin = lib.optional config.hardware.nvidia.enabled config.hardware.nvidia.package.bin;
  # The snapshot and the status screen run the Docker CLI. A host that runs Podman and not
  # Docker serves the Docker API on Podman's socket, which NixOS's Podman module always enables.
  # /run/docker.sock exists only with virtualisation.podman.dockerSocket.enable, which the
  # straylight-software hardware module leaves off.
  containerEnv = lib.optionalAttrs
    (config.virtualisation.podman.enable && !config.virtualisation.docker.enable)
    { DOCKER_HOST = "unix:///run/podman/podman.sock"; };
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
    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Open what mentatd and the agent listen on, TCP 6379, 6380 and 8090 and UDP 6382, on all
        interfaces. Model endpoints, and the ports a group spanning boxes opens at run time, stay
        closed. The README's NixOS section shows how to trust the cluster's interfaces instead.
      '';
    };
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
      "kindling/version".text = builtins.readFile ../../VERSION;
      "spark-os-version".text = "NixOS ${config.system.nixos.version}\n";
    } // lib.optionalAttrs (cfg.connectxMtu != 0) {
      "kindling/connectx-mtu".text = "${toString cfg.connectxMtu}\n";
    } // lib.optionalAttrs (cfg.ethernetMtu != 0) {
      "kindling/ethernet-mtu".text = "${toString cfg.ethernetMtu}\n";
    };

    # The agent reads it from boot, and the snapshot first writes to it 30 seconds in.
    systemd.tmpfiles.rules = [ "d /var/log/spark 0755 root root -" ];

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
      # A switch must not restart mentatd: on the box that heads a model group, that kills the
      # group. A new mentatd takes over at the next boot or a deliberate restart.
      restartIfChanged = false;
      # mentatd announces the name hostname(1) prints, and "unknown" when there is none.
      path = [ pkgs.iproute2 pkgs.hostname ];
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
      # The wrapper puts the agent's own tools on PATH. The unit adds the driver's nvidia-smi.
      path = nvidiaBin;
      environment = {
        AGENT_LOG_DIR = "/var/log/spark";
        SPARK_MEMORY_PY = memory;
        PY_SPY = "${packages.pySpy}/bin/py-spy";
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
      path = with pkgs; [
        coreutils gnugrep gnused gawk procps systemd util-linux docker-client iproute2 packages.sparkMemory
      ] ++ nvidiaBin;
      environment = { SPARK_MEMORY_PY = memory; } // containerEnv;
      serviceConfig = {
        Type = "oneshot";
        Nice = 10;
        IOSchedulingClass = "idle";
        # systemd gives a oneshot no start timeout, and the script's docker calls have none. A
        # stuck Docker or Podman would otherwise freeze the agent's diagnostics until a reboot.
        TimeoutStartSec = "5min";
        ExecStart = "${pkgs.bash}/bin/sh ${../../overlay/usr/local/bin/spark-log-snapshot.sh}";
      };
    };
    systemd.timers.spark-dmesg-snapshot = {
      description = "Refresh Kindling agent diagnostics";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "30s";
        OnUnitActiveSec = "60s";
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

    # Each en* port gets its MTU when it appears, at boot and later: a ConnectX port without a
    # cable is off the PCI bus until one is plugged in. On NetworkManager hosts the dispatcher
    # below sets it again when a profile comes up, since a profile can carry its own MTU.
    systemd.services."sparkos-mtu@" = lib.mkIf mtuEnabled {
      description = "Apply the Kindling MTU to port %i";
      after = [ "network.target" ];
      path = with pkgs; [ coreutils iproute2 ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${mtuScript} %i";
      };
    };
    # NAME is the name udev gives the port. Without a rename rule it is unset, and KERNEL holds
    # it. systemd ignores the add event of a port that udev renames, as a ConnectX port is
    # renamed from eth<N>, and acts on the move event that follows, so match both.
    services.udev.extraRules = lib.mkIf mtuEnabled ''
      ACTION=="add|move", SUBSYSTEM=="net", NAME=="en*", ENV{SYSTEMD_WANTS}+="sparkos-mtu@$name.service"
      ACTION=="add|move", SUBSYSTEM=="net", NAME=="", KERNEL=="en*", ENV{SYSTEMD_WANTS}+="sparkos-mtu@$name.service"
    '';

    networking.networkmanager.dispatcherScripts = lib.mkIf config.networking.networkmanager.enable [
      {
        source = pkgs.writeShellScript "kindling-network-dispatcher" ''
          case "$2" in
            up|down|dhcp4-change|dhcp6-change|connectivity-change)
              ${pkgs.systemd}/bin/systemctl start --no-block sparkos-mentatd-check.service ;;
          esac
          case "$2" in
            up|reapply) ${lib.optionalString mtuEnabled ''exec ${mtuScript} "$1"''} ;;
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
      # As NixOS's own gettys: a restart would hang up whoever logged in on tty1.
      restartIfChanged = false;
      # procps before coreutils: the status screen runs uptime -p, which coreutils' uptime lacks.
      path = with pkgs; [
        procps coreutils iproute2 curl jq gnused gawk gnugrep util-linux ncurses docker-client hostname getent logo
      ] ++ nvidiaBin;
      environment = {
        TERM = "linux";
        SPARK_LOGIN = "${pkgs.shadow}/bin/login";
        SPARK_LOGO_DIR = "${../../overlay/usr/share/kindling}";
      } // containerEnv;
      serviceConfig = {
        ExecStart = "${pkgs.bash}/bin/bash ${../../overlay/usr/local/bin/spark-console}";
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
        ExecStart = "${pkgs.python3}/bin/python3 ${../../overlay/usr/local/bin/spark-watchdog.py}";
        StateDirectory = "spark-watchdog";
        Restart = "on-failure";
        RestartPreventExitStatus = 3;
        KillSignal = "SIGTERM";
        TimeoutStopSec = 30;
      };
    };
  };
}
