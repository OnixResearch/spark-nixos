{
  description = "Kindling Spark host services for an existing NixOS GB10 installation";

  # The module takes nothing from this input. It builds the VM test, and a host flake can
  # point it at its own nixpkgs with kindling.inputs.nixpkgs.follows = "nixpkgs".
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }: {
    nixosModules.default = import ./nix/modules/default.nix;

    checks = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] (system: {
      vm = import ./nix/tests/vm.nix {
        pkgs = nixpkgs.legacyPackages.${system};
        module = self.nixosModules.default;
      };
    });
  };
}
