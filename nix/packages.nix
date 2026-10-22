{ pkgs }:

let
  inherit (pkgs) lib;

  # The release in the Dockerfile's mentat images. Its tag is annotated, so the commit it
  # points at is pinned, not the tag, which can move.
  mentatVersion = "0.20.0";
  mentatSource = pkgs.fetchFromGitHub {
    owner = "kindlingai";
    repo = "mentat";
    rev = "7c37c51c3b17244d4d39f474ad348978d86e9cbc";
    hash = "sha256-YjgZcx5UQYg8LXHkaRyTQIccuKQMNByDTYnfSC3fKVM=";
  };

  # The upstream package is a small Ray-compatible shim named "mentatd", not
  # real Ray. In particular spark-agent uses ray.register.connect().
  rayShim = pkgs.python3Packages.buildPythonPackage {
    pname = "mentatd";
    version = mentatVersion;
    src = "${mentatSource}/python";
    # mentat's repository commits an old setuptools build/ tree, which upstream's .dockerignore
    # keeps out of its wheel. Every file in the store has the same mtime, so setuptools would
    # take those old modules as current and install them.
    postPatch = ''
      rm -rf build mentatd.egg-info
    '';
    pyproject = true;
    build-system = [ pkgs.python3Packages.setuptools ];
    pythonImportsCheck = [ "ray.register" ];
  };

  # py-spy from the wheel the Dockerfile pins (PY_SPY_VERSION, PY_SPY_SHA256), so a NixOS box
  # runs the Ubuntu image's binary whatever the host's nixpkgs is. The nixpkgs that the
  # straylight-software hardware module needs marks its py-spy 0.4.0 broken on aarch64, and the
  # agent would not evaluate there. The wheels hold a static binary. x86_64 is for the VM test.
  pySpyVersion = "0.4.2";
  pySpyWheels = {
    aarch64-linux = {
      platform = "manylinux_2_17_aarch64.manylinux2014_aarch64";
      hash = "sha256-FCiH6YSk5UEHHJmkQB/4w3cPJV0ynb0PZOjB3VGILM4=";
    };
    x86_64-linux = {
      platform = "manylinux_2_5_x86_64.manylinux1_x86_64";
      hash = "sha256-rrAyNAkZnHhfcwZF6fS7enucosSB8sMxpVZCtdE/pS8=";
    };
  };
  pySpy =
    let
      system = pkgs.stdenv.hostPlatform.system;
      wheel = pySpyWheels.${system} or (throw "py-spy: no pinned wheel for ${system}");
    in
    pkgs.stdenvNoCC.mkDerivation {
      pname = "py-spy";
      version = pySpyVersion;
      src = pkgs.fetchurl {
        url = "https://files.pythonhosted.org/packages/py2.py3/p/py-spy/py_spy-${pySpyVersion}-py2.py3-none-${wheel.platform}.whl";
        inherit (wheel) hash;
      };
      dontUnpack = true;
      nativeBuildInputs = [ pkgs.unzip ];
      installPhase = ''
        runHook preInstall
        unzip -q "$src" 'py_spy-${pySpyVersion}.data/scripts/py-spy'
        install -Dm755 'py_spy-${pySpyVersion}.data/scripts/py-spy' "$out/bin/py-spy"
        runHook postInstall
      '';
      # The binary as the wheel ships it.
      dontStrip = true;
      dontPatchELF = true;
      meta = {
        description = "Sampling profiler for Python programs, from the pinned upstream wheel";
        homepage = "https://github.com/benfred/py-spy";
        license = lib.licenses.mit;
        sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
        platforms = lib.attrNames pySpyWheels;
        mainProgram = "py-spy";
      };
    };

  agentPython = pkgs.python3.withPackages (_: [ rayShim ]);
  # No wrapper here puts nvidia-smi on PATH. The NixOS module adds the configured driver's
  # bin output to each unit that runs it.
  agentPath = lib.makeBinPath [
    agentPython
    pkgs.iproute2
    pkgs.rdma-core
    pkgs.procps
    pkgs.pciutils
    pkgs.usbutils
  ];

  memory = pkgs.stdenvNoCC.mkDerivation {
    pname = "spark-memory";
    version = "0.1.0";
    dontUnpack = true;
    nativeBuildInputs = [ pkgs.makeWrapper ];
    installPhase = ''
      runHook preInstall
      install -Dm644 ${../agent/spark-memory.py} "$out/libexec/spark-memory.py"
      mkdir -p "$out/bin"
      makeWrapper ${pkgs.python3}/bin/python3 "$out/bin/spark-memory" \
        --add-flags "$out/libexec/spark-memory.py"
      runHook postInstall
    '';
  };
in
{
  mentatd = pkgs.rustPlatform.buildRustPackage {
    pname = "mentatd";
    version = mentatVersion;
    src = mentatSource;
    cargoRoot = "rust";
    # Copied verbatim from the pinned commit; the Rust builder checks it
    # against rust/Cargo.lock in src without fetching src during evaluation.
    cargoLock.lockFile = ./pkgs/mentat-Cargo.lock;
    cargoBuildFlags = [ "--workspace" ];
    nativeBuildInputs = [ pkgs.makeWrapper ];

    buildAndTestSubdir = "rust";
    postInstall = ''
      install -Dm755 scripts/mentatd-probe-machine "$out/bin/mentatd-probe-machine"
      substituteInPlace "$out/bin/mentatd-probe-machine" \
        --replace-fail '#!/bin/sh' '#!${pkgs.runtimeShell}'
      wrapProgram "$out/bin/mentatd-probe-machine" \
        --prefix PATH : "${lib.makeBinPath [ pkgs.coreutils pkgs.gawk ]}"
      ln -s mentatd "$out/bin/ray"
    '';
    meta = {
      description = "Mentat ${mentatVersion} cluster daemon and host machine probe";
      homepage = "https://github.com/kindlingai/mentat";
      license = with lib.licenses; [ mit asl20 ];
      mainProgram = "mentatd";
    };
  };

  sparkAgent = pkgs.stdenvNoCC.mkDerivation {
    pname = "spark-agent";
    version = "0.1.0";
    dontUnpack = true;
    nativeBuildInputs = [ pkgs.makeWrapper ];
    installPhase = ''
      runHook preInstall
      install -Dm644 ${../agent/spark-agent.py} "$out/libexec/spark-agent.py"
      mkdir -p "$out/bin"
      makeWrapper ${agentPython}/bin/python3 "$out/bin/spark-agent" \
        --add-flags "$out/libexec/spark-agent.py" \
        --prefix PATH : "${agentPath}" \
        --set-default PY_SPY "${pySpy}/bin/py-spy" \
        --set-default SPARK_MEMORY_PY "${memory}/bin/spark-memory"
      runHook postInstall
    '';
    meta.mainProgram = "spark-agent";
  };

  sparkMemory = memory;
  inherit pySpy;
}
