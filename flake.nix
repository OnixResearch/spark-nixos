{
  description = "Kindling Spark host services for an existing NixOS GB10 installation";

  # The module takes nothing from this input. It builds the packages and the checks, and a host
  # flake can point it at its own nixpkgs with kindling.inputs.nixpkgs.follows = "nixpkgs".
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      forAllSystems = f: nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ]
        (system: f nixpkgs.legacyPackages.${system});
    in
    {
      # A path, so option declarations name this file and a second import is a no-op.
      nixosModules.default = ./nix/modules/default.nix;

      # The programs the module runs, to build or reuse on their own.
      packages = forAllSystems (pkgs: import ./nix/packages.nix { inherit pkgs; });

      checks = forAllSystems (pkgs: {
        vm = import ./nix/tests/vm.nix {
          inherit pkgs;
          module = self.nixosModules.default;
        };
      } // nixpkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isAarch64 {
        # dispram against stacks.yaml's default stack, the release it was validated on, so a
        # compiler or nixpkgs change that breaks the -Werror build shows up here.
        dispram = pkgs.callPackage ./nix/pkgs/dispram.nix {
          ogkmVersion = "580.178.04";
          ogkmSource = pkgs.fetchFromGitHub {
            owner = "NVIDIA";
            repo = "open-gpu-kernel-modules";
            rev = "c8e699821c23e4335bf23330a54a23d15cfb95e9";
            hash = "sha256-7eXEROG2rQK9+Ag26nG4jFPrnKeveVUQ0ugIAshJZPQ=";
          };
        };
      });
    };
}
