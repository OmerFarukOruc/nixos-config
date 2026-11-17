{
  lib,
  buildNpmPackage,
  makeWrapper,
  nodejs_26,
}:
buildNpmPackage {
  pname = "cf";
  version = "1.0.0-rc.1";

  src = lib.fileset.toSource {
    root = ./cf;
    fileset = lib.fileset.unions [
      ./cf/package.json
      ./cf/package-lock.json
    ];
  };

  nodejs = nodejs_26;
  npmDepsHash = "sha256-D/JJgK5iWq1gBA/Yy4kI+L5nui/51AQO8bXsCqStn/A=";
  dontNpmBuild = true;

  nativeBuildInputs = [ makeWrapper ];

  postInstall = ''
    makeWrapper ${lib.getExe nodejs_26} $out/bin/cf \
      --add-flags $out/lib/node_modules/cf-cli/node_modules/cf/bin/cf
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    $out/bin/cf --version
    runHook postInstallCheck
  '';

  passthru.npmPackage = "cf";

  meta = {
    description = "Cloudflare's CLI for the whole Cloudflare platform";
    homepage = "https://www.npmjs.com/package/cf";
    license = with lib.licenses; [
      asl20
      mit
    ];
    mainProgram = "cf";
  };
}
