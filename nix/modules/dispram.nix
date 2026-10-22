{ config, lib, pkgs, ... }:

let
  inherit (lib) mkEnableOption mkIf mkOption types;
  cfg = config.services.kindling.dispram;
  # Do not construct a service with missing or contradictory driver/source declarations.
  configured = cfg.ogkmSource != null
    && cfg.validatedDriver != ""
    && cfg.ogkmVersion != ""
    && cfg.ogkmVersion == cfg.validatedDriver;
  package = pkgs.callPackage ../pkgs/dispram.nix {
    inherit (cfg) ogkmSource;
  };
  # The parts of dispram/ that run inside model containers, with their license.
  plugin = lib.fileset.toSource {
    root = ../../dispram;
    fileset = lib.fileset.unions [
      ../../dispram/python
      ../../dispram/vllm
      ../../dispram/LICENSE-GPL
      ../../dispram/BUNDLING-EXCEPTION
    ];
  };
in
{
  options.services.kindling.dispram = {
    enable = mkEnableOption "the GB10 display-carveout lender (dispram)";

    validatedDriver = mkOption {
      type = types.str;
      default = "";
      example = "580.178.04";
      description = ''
        Upstream NVIDIA driver release on which this dispram build was validated.
        This is the exact release checked against /proc/driver/nvidia/version
        before the daemon opens the RM, not an Ubuntu package version. No
        driver is selected or installed by this module.
      '';
    };

    ogkmVersion = mkOption {
      type = types.str;
      default = "";
      example = "580.178.04";
      description = ''
        Release of the caller-supplied NVIDIA open-gpu-kernel-modules source.
        It must equal validatedDriver. Supply a source pinned to the exact
        matching NVIDIA release; for the repo's validated 580.178.04 stack,
        stacks.yaml records commit c8e699821c23e4335bf23330a54a23d15cfb95e9.
      '';
    };

    ogkmSource = mkOption {
      type = types.nullOr (types.either types.path types.package);
      default = null;
      example = lib.literalExpression ''inputs.ogkm.outPath'';
      description = ''
        Externally supplied, reproducibly pinned root of NVIDIA's
        open-gpu-kernel-modules source tree for ogkmVersion. A flake input
        pinned by its lock file or a fixed-output fetcher can supply this;
        a floating branch, tag, or unchecked local checkout must not.
        The RM API headers are built from this tree, not the NixOS driver
        package's potentially different headers.
      '';
    };
  };

  config = {
    assertions = lib.optionals cfg.enable [
      {
        assertion = builtins.match "[0-9]+([.][0-9]+)+" cfg.validatedDriver != null;
        message = "services.kindling.dispram.validatedDriver must declare a nonempty upstream NVIDIA release (for example 580.178.04).";
      }
      {
        assertion = cfg.ogkmSource != null;
        message = "services.kindling.dispram.ogkmSource must be supplied as a pinned matching NVIDIA OGKM source tree.";
      }
      {
        assertion = cfg.ogkmVersion != "" && cfg.ogkmVersion == cfg.validatedDriver;
        message = "services.kindling.dispram.ogkmVersion must declare the same release as validatedDriver.";
      }
    ];

    # Recipes mount the plugin and the socket directory at the Ubuntu image's paths (see
    # dispram/README.md). Both exist whenever Kindling runs, dispramd or not, because Podman
    # refuses to start a container whose bind source is missing. Without dispramd the plugin
    # stands aside.
    systemd.tmpfiles.rules = mkIf config.services.kindling.enable [
      "d /run/dispram 0755 root root -"
      "L+ /opt/kindling/dispram - - - - ${plugin}"
    ];

    systemd.services.dispramd = mkIf (cfg.enable && configured) {
      description = "GB10 display carveout lender (dispram)";
      wantedBy = [ "multi-user.target" ];
      after = [ "nvidia-persistenced.service" ];
      unitConfig.ConditionPathExists = "/dev/nvidiactl";
      environment = {
        DISPRAM_DRIVER = cfg.validatedDriver;
        DISPRAM_LIB = "${package}/lib/dispram/librmlist.so";
        DISPRAM_SOCKET = "/run/dispram/dispram.sock";
      };
      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.python3}/bin/python3 ${package}/libexec/dispram/dispramd.py";
        User = "root";
        RuntimeDirectory = "dispram";
        RuntimeDirectoryMode = "0755";
        # lent.json must survive even a manual stop/restart while borrowers exist.
        RuntimeDirectoryPreserve = "yes";
        Restart = "on-failure";
        RestartSec = 5;
        RestartPreventExitStatus = 3;
      };
    };
  };
}
