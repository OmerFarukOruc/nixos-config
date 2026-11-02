{
  lib,
  buildNpmPackage,
  makeWrapper,
  nodejs_26,
}:
buildNpmPackage {
  pname = "openchamber-web";
  version = "2.6.0";

  src = lib.fileset.toSource {
    root = ./openchamber-web;
    fileset = lib.fileset.unions [
      ./openchamber-web/package.json
      ./openchamber-web/package-lock.json
    ];
  };

  nodejs = nodejs_26;
  npmDepsHash = "sha256-0phVSA26NQPU5F0XWPrtn6t5mtI0E5qOvzV8ayBV2lQ=";
  dontNpmBuild = true;

  nativeBuildInputs = [ makeWrapper ];

  postInstall = ''
    makeWrapper ${lib.getExe nodejs_26} $out/bin/openchamber \
      --add-flags $out/lib/node_modules/openchamber-web-cli/node_modules/@openchamber/web/bin/cli.js
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    $out/bin/openchamber --version
    ${lib.getExe nodejs_26} -e "require('$out/lib/node_modules/openchamber-web-cli/node_modules/node-pty')"
    runHook postInstallCheck
  '';

  passthru.npmPackage = "@openchamber/web";

  meta = {
    description = "OpenChamber, the web UI for OpenCode";
    homepage = "https://github.com/openchamber/openchamber";
    license = lib.licenses.mit;
    mainProgram = "openchamber";
  };
}
