{
  lib,
  buildNpmPackage,
  makeWrapper,
  nodejs_24,
}:
buildNpmPackage {
  pname = "openchamber-web";
  version = "2.5.2";

  src = lib.fileset.toSource {
    root = ./openchamber-web;
    fileset = lib.fileset.unions [
      ./openchamber-web/package.json
      ./openchamber-web/package-lock.json
    ];
  };

  nodejs = nodejs_24;
  npmDepsHash = "sha256-IbAS04B07Kl42LY5wk+mBgGR/qWgpcpQkO+JHTlpggs=";
  dontNpmBuild = true;

  nativeBuildInputs = [ makeWrapper ];

  postInstall = ''
    makeWrapper ${lib.getExe nodejs_24} $out/bin/openchamber \
      --add-flags $out/lib/node_modules/openchamber-web-cli/node_modules/@openchamber/web/bin/cli.js
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    $out/bin/openchamber --version
    ${lib.getExe nodejs_24} -e "require('$out/lib/node_modules/openchamber-web-cli/node_modules/node-pty')"
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
