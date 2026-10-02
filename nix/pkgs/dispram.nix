# OGKM must be a caller-pinned NVIDIA/open-gpu-kernel-modules source tree at the
# exact release declared by services.kindling.dispram.ogkmVersion.
{ stdenv, ogkmSource }:

stdenv.mkDerivation {
  pname = "dispram";
  version = "0.1";
  src = ../../dispram;

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    $CC -O2 -Wall -Werror -shared -fPIC rmlist.c -o librmlist.so \
      -I${ogkmSource}/src/common/sdk/nvidia/inc \
      -I${ogkmSource}/kernel-open/common/inc \
      -I${ogkmSource}/src/nvidia/arch/nvalloc/unix/include
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 librmlist.so "$out/lib/dispram/librmlist.so"
    install -Dm644 dispramd.py "$out/libexec/dispram/dispramd.py"
    mkdir -p "$out/share/dispram/python" "$out/share/licenses/dispram"
    cp -r python/. "$out/share/dispram/python/"
    install -m644 LICENSE LICENSE-GPL BUNDLING-EXCEPTION "$out/share/licenses/dispram/"
    runHook postInstall
  '';

  meta.platforms = [ "aarch64-linux" ];
}
