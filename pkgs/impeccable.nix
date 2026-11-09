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
  version = "4.8.2";

  src = fetchurl {
    url = "https://registry.npmjs.org/impeccable/-/impeccable-${finalAttrs.version}.tgz";
    hash = "sha512-NCEL/OndWjqCgN1hhau4In7zLDMlk/NZim8IcBitSER56hx3/eQecXjRC5+kSV6iRd2d8G5kWwR5agGXse4b3w==";
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
