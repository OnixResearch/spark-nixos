{
  description = "Kindling Spark host services for an existing NixOS GB10 installation";

  outputs = { self }: {
    nixosModules.default = import ./nix/modules/default.nix;
  };
}
