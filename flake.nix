{
  description = "NixOS for NVIDIA GB10 hosts (DGX Spark, ASUS Ascent GX10) running Kindling's cluster services";

  # The modules take nothing from this input. It builds the packages and the checks, and a host
  # flake can point it at its own nixpkgs with spark-nixos.inputs.nixpkgs.follows = "nixpkgs".
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      forAllSystems = f: nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ]
        (system: f nixpkgs.legacyPackages.${system});

      # NVIDIA/open-gpu-kernel-modules at the driver of vendor/kindling-spark-os/stacks.yaml's
      # default stack: the RM API headers dispram was validated against.
      dispramStack = {
        version = "580.178.04";
        rev = "c8e699821c23e4335bf23330a54a23d15cfb95e9";
        hash = "sha256-7eXEROG2rQK9+Ag26nG4jFPrnKeveVUQ0ugIAshJZPQ=";
      };
    in
    {
      # Paths, so option declarations name their files and a second import is a no-op.
      # default is both: the GB10 hardware, and Kindling's services on it.
      nixosModules = {
        default = ./nix/modules;
        hardware = ./nix/modules/hardware;
        kindling = ./nix/modules/kindling;
      };

      # The programs the module runs, to build or reuse on their own.
      packages = forAllSystems (pkgs: import ./nix/packages.nix { inherit pkgs; });

      apps = forAllSystems (pkgs: {
        # nix run .#import-kindling -- <tag>: vendor another kindling-spark-os release.
        import-kindling = {
          type = "app";
          program = pkgs.lib.getExe (pkgs.writeShellApplication {
            name = "import-kindling";
            runtimeInputs = with pkgs; [ coreutils gawk gnused git gnupatch jq ];
            text = builtins.readFile ./scripts/import-kindling.sh;
          });
          meta.description = "Vendor the kindling-spark-os files spark-nixos uses, at one release";
        };
        # nix run .#generate-kernel-config: regenerate kernel-configs/ after a kernel bump in
        # kernel-configs/nvidia-kernel-source.nix. Run it from the checkout's root.
        generate-kernel-config = {
          type = "app";
          program = "${pkgs.writeShellScript "generate-kernel-config" ''
            exec ${pkgs.python3}/bin/python3 ${./scripts/generate-terse-dgx-config.py} "$@"
          ''}";
          meta.description = "Generate the terse GB10 kernel configuration from NVIDIA's annotations";
        };
      });

      checks = forAllSystems (pkgs: {
        # The generator's own tests, on dummy configs. The ones that need nix skip themselves.
        kernel-config-tests = pkgs.runCommand "kernel-config-tests"
          {
            src = pkgs.lib.fileset.toSource {
              root = ./.;
              fileset = pkgs.lib.fileset.unions [ ./scripts/generate-terse-dgx-config.py ./tests ];
            };
            nativeBuildInputs = [ (pkgs.python3.withPackages (ps: [ ps.pytest ])) ];
          } ''
          cd "$src/tests"
          python3 -m pytest -p no:cacheprovider test_generate_config.py -v
          touch "$out"
        '';
        hardware-eval = import ./nix/checks/hardware-eval.nix {
          inherit pkgs nixpkgs dispramStack;
          module = self.nixosModules.default;
        };
        vendor = import ./nix/checks/vendor.nix { inherit pkgs; };
        vm = import ./nix/tests/vm.nix {
          inherit pkgs;
          module = self.nixosModules.default;
        };
      } // nixpkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isAarch64 {
        # dispram against stacks.yaml's default stack, the release it was validated on, so a
        # compiler or nixpkgs change that breaks the -Werror build shows up here.
        dispram = pkgs.callPackage ./nix/pkgs/dispram.nix {
          ogkmVersion = dispramStack.version;
          ogkmSource = pkgs.fetchFromGitHub {
            owner = "NVIDIA";
            repo = "open-gpu-kernel-modules";
            inherit (dispramStack) rev hash;
          };
        };
      });
    };
}
