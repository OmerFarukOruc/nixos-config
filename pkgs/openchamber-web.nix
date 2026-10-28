# OpenChamber's web server (risoluto-dev-1), from npm; pkgs/openchamber.nix is
# the desktop app. openchamber-web/package.json is a wrapper project that
# depends on @openchamber/web, with the lockfile npm wrote for it.
# scripts/update-app.sh rewrites both and npmDepsHash for a new release.
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

  # A new release can add a native module that builds but does not load, so
  # the check loads the terminal one and starts the CLI.
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
