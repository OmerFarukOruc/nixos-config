# Cloudflare's cf CLI, from npm. It has only beta releases, and its own
# package.json pins dev dependencies that do not resolve, so cf/package.json
# is a wrapper project that depends on cf, with the lockfile npm wrote for it.
# scripts/update-app.sh rewrites both and npmDepsHash for a new release.
# Its workerd binary (cf dev) runs through nix-ld (nixosModules/common.nix).
{
  lib,
  buildNpmPackage,
  makeWrapper,
  nodejs_24,
}:
buildNpmPackage {
  pname = "cf";
  version = "1.0.0-beta.24";

  src = lib.fileset.toSource {
    root = ./cf;
    fileset = lib.fileset.unions [
      ./cf/package.json
      ./cf/package-lock.json
    ];
  };

  nodejs = nodejs_24;
  npmDepsHash = "sha256-MHt1YbEm5bwCC9PT5DV30Jsy0baYTFbTCOY9ELbd+XQ=";
  dontNpmBuild = true;

  nativeBuildInputs = [ makeWrapper ];

  postInstall = ''
    makeWrapper ${lib.getExe nodejs_24} $out/bin/cf \
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
