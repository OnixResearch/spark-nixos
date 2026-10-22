{ pkgs }:

let
  inherit (pkgs) lib;

  # v0.19.0 is an annotated tag; the peeled commit is pinned rather than the
  # mutable tag. This is the same release as the Dockerfile's mentat images.
  mentatSource = pkgs.fetchFromGitHub {
    owner = "mmastrac";
    repo = "mentat";
    rev = "717e767ff0221d60056726eff3c94b2968d7c6af";
    hash = "sha256-Gi/0ZmH+XU2ZYm/fosup4UD7Nsp7a0aKd2ij4PlJTUM=";
  };

  # The upstream package is a small Ray-compatible shim named "mentatd", not
  # real Ray. In particular spark-agent uses ray.register.connect().
  rayShim = pkgs.python3Packages.buildPythonPackage {
    pname = "mentatd";
    version = "0.19.0";
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
    version = "0.19.0";
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
      description = "Mentat 0.19.0 cluster daemon and host machine probe";
      homepage = "https://github.com/mmastrac/mentat";
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
