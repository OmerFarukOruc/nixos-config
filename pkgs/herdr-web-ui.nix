# herdr's web UI (github.com/devswha/herdr-web-ui), served on risoluto-dev-1.
# Bun installs the locked dependencies, with the patches its package.json
# names, in a fixed-output derivation; the client is built here, so the
# server starts with no build. The server runs its PTY sidecar on Node, which
# the wrapper puts on PATH; without it panes are only mirrored.
{
  lib,
  stdenv,
  stdenvNoCC,
  fetchFromGitHub,
  autoPatchelfHook,
  bun,
  makeWrapper,
  nodejs_24,
}:
let
  version = "0.4.19";
  src = fetchFromGitHub {
    owner = "devswha";
    repo = "herdr-web-ui";
    tag = "v${version}";
    hash = "sha256-0MKjG/i4GSqLQIISqCJi5PbyAsax2EGADsV9Spj6IzU=";
  };
  deps = stdenvNoCC.mkDerivation {
    pname = "herdr-web-ui-deps";
    inherit version src;
    nativeBuildInputs = [ bun ];
    dontConfigure = true;
    buildPhase = ''
      export HOME=$TMPDIR
      bun install --frozen-lockfile --ignore-scripts --no-progress
    '';
    installPhase = "cp -a node_modules $out";
    dontFixup = true;
    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    outputHash = "sha256-z+VixbLf06pkZDH5qYj8pukmVmhuafCWhMR8fUmdKPk=";
  };
in
stdenv.mkDerivation {
  pname = "herdr-web-ui";
  inherit version src;

  nativeBuildInputs = [
    autoPatchelfHook
    bun
    makeWrapper
  ];
  # node-pty's prebuilt module links the C++ runtime.
  buildInputs = [ stdenv.cc.cc.lib ];

  configurePhase = ''
    cp -a ${deps} node_modules
    chmod -R u+w node_modules
  '';
  buildPhase = ''
    export HOME=$TMPDIR
    bun --bun node_modules/vite/bin/vite.js build
  '';
  installPhase = ''
    mkdir -p $out/lib/herdr-web-ui $out/bin
    cp -a . $out/lib/herdr-web-ui
    makeWrapper ${lib.getExe bun} $out/bin/herdr-web-ui \
      --chdir $out/lib/herdr-web-ui \
      --prefix PATH : ${lib.makeBinPath [ nodejs_24 ]} \
      --add-flags "run server/managed.ts"
  '';
  # Only node-pty's Linux x64 module needs its loader set; the other
  # platforms' prebuilds stay as they are.
  autoPatchelfIgnoreMissingDeps = true;

  passthru.githubRepo = "devswha/herdr-web-ui";
  # The bun that made outputHash; update-app.sh learns the hash again when
  # nixpkgs' bun differs.
  passthru.depsBun = "1.4.2";

  meta = {
    description = "Web UI for herdr sessions";
    homepage = "https://github.com/devswha/herdr-web-ui";
    license = lib.licenses.mit;
    mainProgram = "herdr-web-ui";
  };
}
