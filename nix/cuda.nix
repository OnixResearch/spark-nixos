# The host's nixpkgs again, with CUDA on for the GB10 only (compute capabilities 12.0 and 12.1),
# graham33's CUDA 13.4 fixes, and mentat's client in place of Ray. Model engines come from here.
# The host's own packages stay without CUDA, so they still come from cache.nixos.org.
{ pkgs }:

import pkgs.path {
  inherit (pkgs.stdenv.hostPlatform) system;
  config = pkgs.config // {
    allowUnfree = true;
    cudaSupport = true;
    cudaCapabilities = [ "12.0" "12.1" ];
  };
  overlays = pkgs.overlays ++ [
    (import ./overlays/cuda-fixes.nix)
    (import ./overlays/vllm-mentat.nix)
  ];
}
