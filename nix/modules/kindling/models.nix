# Kindling models in NixOS containers: each model is a systemd-nspawn container that shares the
# host's network and Nix store, and runs its engine as a service. It joins mentat as a recipe's
# OCI container does (mentat's GUIDE.md and GUIDE-SERVE.md), so it needs no container runtime,
# no image and no NVIDIA container toolkit.
{ config, lib, pkgs, ... }:

let
  inherit (lib) literalExpression mkIf mkOption types;
  hostConfig = config;
  kindling = config.services.kindling;
  packages = import ../../packages.nix { inherit pkgs; };
  cuda = import ../../cuda.nix { inherit pkgs; };
  models = lib.filterAttrs (_: m: m.enable) kindling.models;

  # The single-rank registration needs only mentat's client.
  registerPython = pkgs.python3.withPackages (_: [ packages.rayShim ]);

  # The agent's log tools read /var/log/spark, so the snapshot copies each model's engine log
  # there, and the list of running containers, as it does for Docker's.
  modelsSnapshot = pkgs.writeShellScript "kindling-models-snapshot" ''
    set -u
    PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.systemd ]}
    LOGDIR=''${AGENT_LOG_DIR:-/var/log/spark}
    atomic() { cat > "$1.tmp" && mv -f "$1.tmp" "$1"; }
    machinectl list --no-legend --no-pager 2>&1 | atomic "$LOGDIR/machines.log"
    for m in ${lib.escapeShellArgs (lib.attrNames models)}; do
      journalctl -M "$m" -u engine -n 300 --no-pager -o short-iso 2>&1 | atomic "$LOGDIR/model-$m.log"
    done
  '';

  # The device nodes CUDA opens, as the NVIDIA container toolkit passes them for --gpus all.
  gpuNodes = [ "/dev/nvidia0" "/dev/nvidiactl" "/dev/nvidia-uvm" "/dev/nvidia-uvm-tools" ];

  modelOptions = { name, ... }: {
    options = {
      enable = lib.mkEnableOption "this model" // { default = true; };

      group = mkOption {
        type = types.str;
        default = name;
        description = ''
          The model's mentat group (`MENTAT_GROUP`). Every box that runs a rank of one model uses
          the same group.
        '';
      };

      command = mkOption {
        type = types.listOf types.str;
        example = literalExpression ''
          [
            "''${config.services.kindling.vllm}/bin/vllm" "serve" "/models/qwen3-8b"
            "--port" "8000" "--enforce-eager" "--safetensors-load-strategy" "eager"
          ]
        '';
        description = ''
          The engine's command line, run in the model's container. Packages come from the
          host's store, which the container shares.
        '';
      };

      openaiPort = mkOption {
        type = types.nullOr types.port;
        default = 8000;
        description = ''
          The port the engine serves its OpenAI API on (`MENTAT_OPENAI_API`). The router probes
          its `/v1/models` and routes the names it lists there. null on a rank that serves none.
        '';
      };

      mcpPort = mkOption {
        type = types.nullOr types.port;
        default = null;
        description = "The port of the engine's MCP status server (`MENTAT_MCP_API`), if it has one.";
      };

      provider = mkOption {
        type = types.str;
        default = "vllm";
        description = "The engine's label for mentat (`MENTAT_MODEL_PROVIDER`).";
      };

      distributed = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Start mentat's agent (`ray start`) before the engine, for an engine that places ranks
          on other boxes through vLLM's Ray executor (`--distributed-executor-backend ray`).
          Otherwise the model registers as a single rank (`python -m ray.register`).
        '';
      };

      python = mkOption {
        type = types.package;
        default = kindling.vllmPython;
        defaultText = literalExpression "config.services.kindling.vllmPython";
        description = ''
          With `distributed`, the Python mentat's agent starts the engine's other ranks with
          (`MENTAT_PYTHON`). It needs the engine's packages.
        '';
      };

      environment = mkOption {
        type = types.attrsOf types.str;
        default = { };
        example = { HF_HOME = "/cache/huggingface"; };
        description = "More environment for the engine.";
      };

      bindMounts = mkOption {
        type = types.attrsOf (types.submodule {
          options = {
            hostPath = mkOption { type = types.str; description = "The host's directory or file."; };
            isReadOnly = mkOption { type = types.bool; default = true; description = "Mount it read-only."; };
          };
        });
        default = { };
        example = { "/models/qwen3-8b".hostPath = "/srv/models/qwen3-8b"; };
        description = "Host paths to mount in the container, by mount point: weights, caches, logs.";
      };

      gpu = mkOption {
        type = types.bool;
        default = hostConfig.hardware.nvidia.enabled;
        defaultText = literalExpression "config.hardware.nvidia.enabled";
        description = ''
          Give the container the GPU: its device nodes, and the host's driver libraries at
          `/run/opengl-driver`, where Nix-built CUDA programs look for them.
        '';
      };

      rdma = mkOption {
        type = types.bool;
        default = hostConfig.hardware.dgx-spark.enable or false;
        defaultText = literalExpression "config.hardware.dgx-spark.enable";
        description = ''
          Give the container `/dev/infiniband`, for NCCL over the ConnectX ports, as recipes do.
          Ports that appear later, as a ConnectX port does when its cable goes in, show up there
          too.
        '';
      };

      dispram = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Mount dispram's socket directory and put its vLLM plugin on `PYTHONPATH`, as
          `vendor/kindling-spark-os/dispram/README.md` tells recipes to. Without dispramd the
          plugin stands aside.
        '';
      };

      autoStart = mkOption {
        type = types.bool;
        default = true;
        description = "Start the model at boot.";
      };
    };
  };

  container = name: m: {
    autoStart = m.autoStart;
    # The host's network, as recipes' network_mode: host: mentatd answers on 127.0.0.1:6379,
    # NCCL reaches the fabric, and the router reaches the engine's port.
    privateNetwork = false;
    # As for mentatd: a switch must not restart a model that is serving.
    restartIfChanged = false;
    bindMounts =
      lib.mapAttrs (_: b: { inherit (b) hostPath isReadOnly; }) m.bindMounts
      // lib.optionalAttrs m.gpu (
        lib.genAttrs gpuNodes (node: { hostPath = node; isReadOnly = false; })
        // { "/run/opengl-driver" = { hostPath = "/run/opengl-driver"; isReadOnly = true; }; }
      )
      // lib.optionalAttrs m.rdma {
        "/dev/infiniband" = { hostPath = "/dev/infiniband"; isReadOnly = false; };
      }
      // lib.optionalAttrs m.dispram {
        "/run/dispram" = { hostPath = "/run/dispram"; isReadOnly = false; };
        "/opt/kindling/dispram" = { hostPath = "/opt/kindling/dispram"; isReadOnly = true; };
      };
    allowedDevices =
      lib.optionals m.gpu (map (node: { inherit node; modifier = "rw"; }) gpuNodes)
      ++ lib.optionals m.rdma [
        { node = "char-infiniband_verbs"; modifier = "rw"; }
        { node = "/dev/infiniband/rdma_cm"; modifier = "rw"; }
      ];
    # Recipes run with unlimited memlock (RDMA pins what it registers), a 64 MiB stack and no
    # core dumps, which can hold the driver's lock while they are written.
    extraFlags = [
      "--rlimit=RLIMIT_MEMLOCK=infinity"
      "--rlimit=RLIMIT_STACK=67108864"
      "--rlimit=RLIMIT_CORE=0"
    ];
    config = {
      system.stateVersion = hostConfig.system.stateVersion;
      # The container shares the host's network namespace. Its own firewall would only fail,
      # for want of CAP_NET_ADMIN, and the host's covers the engine's ports.
      networking.firewall.enable = false;

      systemd.services.engine = {
        description = "Kindling model ${name}";
        wantedBy = [ "multi-user.target" ];
        environment =
          {
            MENTAT_GROUP = m.group;
            MENTAT_MODEL_PROVIDER = m.provider;
            CONTAINER_NAME = name;
          }
          // lib.optionalAttrs (m.openaiPort != null) { MENTAT_OPENAI_API = "${toString m.openaiPort}/v1"; }
          // lib.optionalAttrs (m.mcpPort != null) { MENTAT_MCP_API = "${toString m.mcpPort}/mcp"; }
          // lib.optionalAttrs m.distributed {
            VLLM_USE_RAY_V2_EXECUTOR_BACKEND = "1";
            MENTAT_PYTHON = "${m.python}/bin/python3";
          }
          // lib.optionalAttrs m.dispram { PYTHONPATH = "/opt/kindling/dispram/python"; }
          // m.environment;
        script =
          (if m.distributed then ''
            # mentat's agent, in place of Ray's. It detaches, and holds the engine's other ranks.
            ${packages.mentatd}/bin/ray start
          '' else ''
            # One rank: hold a registration with the box's mentatd while the engine runs.
            ${registerPython}/bin/python3 -m ray.register &
          '')
          + "exec ${lib.escapeShellArgs m.command}\n";
        serviceConfig = {
          Restart = "on-failure";
          RestartSec = 10;
          TimeoutStopSec = 30;
          LimitMEMLOCK = "infinity";
          LimitSTACK = 67108864;
          LimitCORE = 0;
        };
      };
    };
  };
in
{
  options.services.kindling = {
    models = mkOption {
      type = types.attrsOf (types.submodule modelOptions);
      default = { };
      description = ''
        Models this box serves, each in a NixOS container (systemd-nspawn) named after it, which
        shares the host's network and Nix store. Each registers with this box's mentatd as a
        recipe's container does. The name must not contain underscores.
      '';
    };

    vllm = mkOption {
      type = types.package;
      default = cuda.python3Packages.vllm;
      defaultText = literalExpression "vLLM from nixpkgs, built with CUDA for the GB10 and mentat's client in place of Ray";
      description = ''
        vLLM for models' `command`. The default builds with CUDA 13.4 for compute capabilities
        12.0 and 12.1, with graham33's fixes, and with mentat's client in place of Ray. No public
        cache holds it, so the first build runs on the box.
      '';
    };

    vllmPython = mkOption {
      type = types.package;
      default = cuda.python3.withPackages (ps: [ ps.vllm ]);
      defaultText = literalExpression "a Python with config.services.kindling.vllm";
      description = "A Python with `vllm`, for a distributed model's other ranks.";
    };
  };

  config = mkIf (kindling.enable && models != { }) {
    containers = lib.mapAttrs container models;

    # A ConnectX port's RDMA devices appear under /dev/infiniband only once its cable is in, so
    # make the directory a model binds exist from boot.
    systemd.tmpfiles.rules = lib.optional (lib.any (m: m.rdma) (lib.attrValues models))
      "d /dev/infiniband 0755 root root -";

    systemd.services =
      lib.mapAttrs'
        (name: m: lib.nameValuePair "container@${name}" {
          after = [ "mentatd.service" ] ++ lib.optional m.gpu "kindling-gpu-nodes.service";
          requires = lib.optional m.gpu "kindling-gpu-nodes.service";
        })
        models
      // {
        spark-dmesg-snapshot.serviceConfig.ExecStartPost = [ "${modelsSnapshot}" ];

        # NixOS's NVIDIA module makes the device nodes from udev as the modules load, and a
        # container cannot start with a bind source missing. Make them again, in order, before
        # any model starts.
        kindling-gpu-nodes = mkIf (lib.any (m: m.gpu) (lib.attrValues models)) {
          description = "Create the NVIDIA device nodes Kindling's models use";
          after = [ "systemd-modules-load.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = [
              "${pkgs.nvidia-modprobe}/bin/nvidia-modprobe -c 0"
              "${pkgs.nvidia-modprobe}/bin/nvidia-modprobe -u -c 0"
            ];
          };
        };
      };
  };
}
