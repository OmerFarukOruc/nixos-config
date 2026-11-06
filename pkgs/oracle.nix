{
  lib,
  buildNpmPackage,
  makeWrapper,
  nodejs_26,
}:
buildNpmPackage {
  pname = "oracle";
  version = "0.23.0";

  src = lib.fileset.toSource {
    root = ./oracle;
    fileset = lib.fileset.unions [
      ./oracle/package.json
      ./oracle/package-lock.json
    ];
  };

  nodejs = nodejs_26;
  npmDepsHash = "sha256-pNFH4iQRjFUQ0DmfEWw0fZB2AMnAa+LR61sfvaKxxvg=";
  dontNpmBuild = true;

  nativeBuildInputs = [ makeWrapper ];

  postInstall = ''
    makeWrapper ${lib.getExe nodejs_26} $out/bin/oracle \
      --add-flags $out/lib/node_modules/oracle-cli/node_modules/@steipete/oracle/dist/bin/oracle-cli.js
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    $out/bin/oracle --version
    runHook postInstallCheck
  '';

  passthru.npmPackage = "@steipete/oracle";

  meta = {
    description = "CLI that sends a prompt and files to ChatGPT or an API model for a second opinion";
    homepage = "https://github.com/steipete/oracle";
    license = lib.licenses.mit;
    mainProgram = "oracle";
  };
}
