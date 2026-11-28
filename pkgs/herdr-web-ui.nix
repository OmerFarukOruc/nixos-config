{
  lib,
  stdenv,
  stdenvNoCC,
  fetchFromGitHub,
  rustPlatform,
  autoPatchelfHook,
  bun,
  makeWrapper,
}:
let
  version = "0.5.13";
  src = fetchFromGitHub {
    owner = "devswha";
    repo = "ovis";
    tag = "v${version}";
    hash = "sha256-85n3S5I9oEw/6BJdGj5SN6SGFRXKXKEL3//I7sSTbvg=";
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
    outputHash = "sha256-UraUIJWrNlc/jhayztd2r1MvvKYmlqE0ajUjxatAmCU=";
  };
  crate =
    {
      name,
      cargoHash,
      checkFlags ? [ ],
    }:
    rustPlatform.buildRustPackage {
      pname = "ovis-${name}";
      inherit
        version
        src
        cargoHash
        checkFlags
        ;
      sourceRoot = "${src.name}/crates/${name}";
      meta.mainProgram = "ovis-${name}";
    };
  ptyHost = crate {
    name = "pty-sidecar";
    cargoHash = "sha256-vin5SGninwkDlpWIK4Cc5oO4cZ7DjTXDovUpu0fWwlE=";
  };
  acpKeeper = crate {
    name = "acp-keeper";
    cargoHash = "sha256-3eyrGrkgc8zW7VIpCXW1iiIrNjmChRf/ylVE2b8LRRc=";
    # The test runs /bin/sleep and /bin/true, which the Nix build sandbox lacks.
    checkFlags = [ "--skip=a_stuck_scope_probe_does_not_stop_the_keeper_running" ];
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
    rm -rf -- node_modules/lightningcss-linux-x64-musl node_modules/@rolldown/binding-linux-x64-musl
    mkdir -p $out/lib/herdr-web-ui $out/bin
    cp -a . $out/lib/herdr-web-ui
    for bin in ${lib.getExe ptyHost} ${lib.getExe acpKeeper}; do
      release=$out/lib/herdr-web-ui/crates/''${bin##*/ovis-}/target/release
      mkdir -p $release
      ln -s $bin $release/
    done
    makeWrapper ${lib.getExe bun} $out/bin/herdr-web-ui \
      --chdir $out/lib/herdr-web-ui \
      --add-flags "run server/managed.ts"
  '';
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    (cd $out/lib/herdr-web-ui && ${lib.getExe bun} -e '
      import { rustSidecar } from "./server/pty/host.ts";
      import { acpKeeperBin } from "./server/acp/keeper-bin.ts";
      process.exit(rustSidecar() === null || acpKeeperBin() === null ? 1 : 0);
    ')
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
