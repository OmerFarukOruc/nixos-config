{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  makeWrapper,
  bash,
  python3,
  bubblewrap,
  coreutils,
  curl,
  findutils,
  gawk,
  gh,
  git,
  glow,
  gnugrep,
  gnused,
  iproute2,
  jq,
  less,
  procps,
  util-linux,
}:
let
  dryer = python3.pkgs.buildPythonPackage {
    pname = "dryer";
    version = "0.1.0-unstable-2026-10-03";
    pyproject = true;
    src = fetchFromGitHub {
      owner = "unclebob";
      repo = "dryer";
      rev = "66ff6d21a42c04afcad89c78a80066176d1294b0";
      hash = "sha256-EwoP89k6YllcN6dmn/rxbeqDoAMOQsKfjpzfykD6PKA=";
    };
    build-system = [ python3.pkgs.setuptools ];
    dependencies = [
      python3.pkgs.tree-sitter
      python3.pkgs.tree-sitter-language-pack
    ];
    pythonImportsCheck = [ "dryer.cli" ];
  };
  shellTools = [
    bubblewrap
    coreutils
    curl
    findutils
    gawk
    gh
    git
    glow
    gnugrep
    gnused
    iproute2
    jq
    less
    procps
    util-linux
  ];
in
stdenvNoCC.mkDerivation {
  pname = "agent-tools";
  version = "0";
  src = ./agent-tools;
  nativeBuildInputs = [ makeWrapper ];
  buildInputs = [
    bash
    python3
  ];
  installPhase = ''
    runHook preInstall
    install -Dm755 -t $out/bin bin/*
    install -Dm644 -t $out/share/agent-tools share/browser-lend.ps1
    substituteInPlace $out/bin/dryer --replace-fail @python@ ${
      lib.getExe (python3.withPackages (_: [ dryer ]))
    }
    for f in $out/bin/*; do
      if head -1 "$f" | grep -q bash; then
        wrapProgram "$f" --prefix PATH : $out/bin:${lib.makeBinPath shellTools}
      fi
    done
    runHook postInstall
  '';
  meta.description = "Omer's agent commands: pr-land, wait-exit, path-claims, dryer, sandbox-run and the others in agent-tools/bin";
}
