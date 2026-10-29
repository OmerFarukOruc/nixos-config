{
  lib,
  stdenv,
  stdenvNoCC,
  fetchFromGitHub,
  autoPatchelfHook,
  bun,
  makeWrapper,
  nodejs_26,
}:
let
  version = "0.4.20";
  src = fetchFromGitHub {
    owner = "devswha";
    repo = "ovis";
    tag = "v${version}";
    hash = "sha256-GEJCpmJ76l+2Qxy8zZdJoaDZJdaxp5jm2bVZxzFRRtQ=";
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
    outputHash = "sha256-qsp4ZE4qMDWqZ37t/AgYuEOXV7QMKS8coKj3nGzyRww=";
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
      --prefix PATH : ${lib.makeBinPath [ nodejs_26 ]} \
      --add-flags "run server/managed.ts"
  '';
  # Only node-pty's Linux x64 module needs its loader set; the other
  # platforms' prebuilds stay as they are.
  autoPatchelfIgnoreMissingDeps = true;

  passthru.githubRepo = "devswha/ovis";
  passthru.depsBun = "1.4.2";

  meta = {
    description = "Web UI for herdr sessions";
    homepage = "https://github.com/devswha/ovis";
    license = lib.licenses.mit;
    mainProgram = "herdr-web-ui";
  };
}
