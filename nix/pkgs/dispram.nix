# OGKM must be a caller-pinned NVIDIA/open-gpu-kernel-modules source tree at the
# exact release declared by services.kindling.dispram.ogkmVersion.
{ lib, stdenv, ogkmSource, ogkmVersion }:

stdenv.mkDerivation {
  pname = "dispram";
  version = "0.1";
  # Only what is built and installed, so an edit elsewhere in dispram/ leaves dispramd alone.
  src = lib.fileset.toSource {
    root = ../../dispram;
    fileset = lib.fileset.unions [
      ../../dispram/rmlist.c
      ../../dispram/dispramd.py
      ../../dispram/LICENSE
    ];
  };

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    # The RM structures rmlist.c passes change between releases, so the headers must come from
    # the declared one. OGKM records its release in version.mk.
    have=$(sed -n 's/^NVIDIA_VERSION[[:space:]]*=[[:space:]]*//p' ${ogkmSource}/version.mk)
    if [ "$have" != ${lib.escapeShellArg ogkmVersion} ]; then
      echo "ogkmSource holds open-gpu-kernel-modules '$have', not ogkmVersion ${ogkmVersion}" >&2
      exit 1
    fi
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
    install -Dm644 LICENSE "$out/share/licenses/dispram/LICENSE"
    runHook postInstall
  '';

  meta.platforms = [ "aarch64-linux" ];
}
