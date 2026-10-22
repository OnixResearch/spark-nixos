# Evaluates a whole GB10 host, NVIDIA kernel and driver included, with every Kindling service on
# and two vLLM models in NixOS containers, one a rank of a model spread over boxes, for the 4K and
# the 64K kernel, without building anything. A nixpkgs bump that breaks the kernel, the CUDA
# vLLM or either module fails here, on any build machine. Derived from graham33's
# checks/dgx-spark-eval.nix.
{ pkgs, nixpkgs, module, dispramStack }:

let
  host = extra: nixpkgs.lib.nixosSystem {
    modules = [
      module
      ({ config, pkgs, ... }: {
        nixpkgs.hostPlatform = "aarch64-linux";
        fileSystems."/" = { device = "/dev/disk/by-label/nixos"; fsType = "ext4"; };
        boot.loader.systemd-boot.enable = true;
        system.stateVersion = "26.05";
        networking.hostName = "spark";
        hardware.dgx-spark.enable = true;
        services.kindling = {
          enable = true;
          openFirewall = true;
          console.enable = true;
          watchdog.enable = true;
          connectxMtu = 4096;
          ethernetMtu = 9000;
          dispram = {
            enable = true;
            validatedDriver = dispramStack.version;
            ogkmVersion = dispramStack.version;
            ogkmSource = pkgs.fetchFromGitHub {
              owner = "NVIDIA";
              repo = "open-gpu-kernel-modules";
              inherit (dispramStack) rev hash;
            };
          };
          models.qwen = {
            command = [
              "${config.services.kindling.vllm}/bin/vllm" "serve" "/models/qwen3-8b"
              "--port" "8000" "--enforce-eager" "--safetensors-load-strategy" "eager"
            ];
            bindMounts."/models/qwen3-8b".hostPath = "/srv/models/qwen3-8b";
            dispram = true;
          };
          models.glm = {
            distributed = true;
            openaiPort = 8002;
            command = [
              "${config.services.kindling.vllm}/bin/vllm" "serve" "/models/glm"
              "--port" "8002" "--distributed-executor-backend" "ray" "--tensor-parallel-size" "2"
            ];
            bindMounts."/models/glm".hostPath = "/srv/models/glm";
          };
        };
      })
      extra
    ];
  };
  drvPath = system: builtins.unsafeDiscardStringContext system.config.system.build.toplevel.drvPath;

  # graham33's #145: system76-power resets the Spark during boot on the NVIDIA kernel.
  tripsSystem76 = system: builtins.any
    (a: !a.assertion && pkgs.lib.hasInfix "system76" a.message)
    system.config.assertions;
  base = host { };
in
assert !(tripsSystem76 base);
assert tripsSystem76 (host { hardware.system76.power-daemon.enable = true; });
pkgs.runCommand "hardware-eval"
{
  drvPath4k = drvPath base;
  drvPath64k = drvPath (host { hardware.dgx-spark.use64kKernel = true; });
} ''
  printf '%s\n' "$drvPath4k" "$drvPath64k" > "$out"
''
