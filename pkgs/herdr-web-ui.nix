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
  version = "0.5.2";
  src = fetchFromGitHub {
    owner = "devswha";
    repo = "ovis";
    tag = "v${version}";
    hash = "sha256-RJI/KywvzCa7MALzcDZz+8G51V7N/ze/joUi86z3rTc=";
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
    outputHash = "sha256-I04k5osKQhXYkPZWCH3LtPiflCIgYJhq2pk7NpumUno=";
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
    rm -r node_modules/lightningcss-linux-x64-musl node_modules/@rolldown/binding-linux-x64-musl
    mkdir -p $out/lib/herdr-web-ui $out/bin
    cp -a . $out/lib/herdr-web-ui
    makeWrapper ${lib.getExe bun} $out/bin/herdr-web-ui \
      --chdir $out/lib/herdr-web-ui \
      --prefix PATH : ${lib.makeBinPath [ nodejs_26 ]} \
      --add-flags "run server/managed.ts"
  '';
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    ${lib.getExe nodejs_26} -e "require('$out/lib/herdr-web-ui/node_modules/@lydell/node-pty')"
    runHook postInstallCheck
  '';

  passthru.githubRepo = "devswha/ovis";
  passthru.depsBun = "1.4.4";

  meta = {
    description = "Web UI for herdr sessions";
    homepage = "https://github.com/devswha/ovis";
    license = lib.licenses.mit;
    mainProgram = "herdr-web-ui";
  };
}
