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
    pyproject = true;
    build-system = [ pkgs.python3Packages.setuptools ];
    pythonImportsCheck = [ "ray.register" ];
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
        --set-default PY_SPY "${pkgs.py-spy}/bin/py-spy" \
        --set-default SPARK_MEMORY_PY "${memory}/bin/spark-memory"
      runHook postInstall
    '';
    meta.mainProgram = "spark-agent";
  };

  sparkMemory = memory;
}
