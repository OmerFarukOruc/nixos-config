# The impeccable CLI that the impeccable skill calls, from npm. The tarball is
# a Node shim: on its first run it downloads the engine binary of its
# optional dependency @impeccable/cli-linux-x64 into ~/.impeccable/bin and
# checks it against the checksums it ships, so that run needs the network.
{
  lib,
  stdenvNoCC,
  fetchurl,
  makeWrapper,
  nodejs_26,
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "impeccable";
  version = "4.8.0";

  src = fetchurl {
    url = "https://registry.npmjs.org/impeccable/-/impeccable-${finalAttrs.version}.tgz";
    hash = "sha512-e0+wbJppJMiQN8npKmIkBbKetfSlarak7OIGlsRhc8folekz4PgStjuprhYi+imjqBb6OCMJLV9II2hHGmcCyg==";
  };

  nativeBuildInputs = [ makeWrapper ];

  passthru.npmPackage = "impeccable";

  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib/impeccable
    cp -r . $out/lib/impeccable
    makeWrapper ${lib.getExe nodejs_26} $out/bin/impeccable \
      --add-flags $out/lib/impeccable/cli/bin/cli.js
    runHook postInstall
  '';

  meta = {
    description = "CLI of the impeccable design skill";
    homepage = "https://www.npmjs.com/package/impeccable";
    license = lib.licenses.asl20;
    mainProgram = "impeccable";
  };
})
