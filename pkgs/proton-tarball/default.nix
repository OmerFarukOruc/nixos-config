{
  lib,
  stdenvNoCC,
  pname,
  version,
  src,
  steamDisplayName,
  homepage,
  description,
  passthru,
}:
stdenvNoCC.mkDerivation {
  inherit
    pname
    version
    src
    passthru
    ;

  outputs = [
    "out"
    "steamcompattool"
  ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    echo "${pname} should not be installed into environments. Use programs.steam.extraCompatPackages instead." > $out
    mkdir $steamcompattool
    cp -r -t $steamcompattool ./*
    chmod -R u+rwX,go+rX $steamcompattool
    runHook postInstall
  '';

  preFixup = ''
    substituteInPlace "$steamcompattool/compatibilitytool.vdf" \
      --replace-fail "${pname}-${version}-x86_64_v3" "${steamDisplayName}"
    ${import ./reapply-wine-inf.nix}
  '';

  meta = {
    inherit homepage description;
    license = lib.licenses.bsd3;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
  };
}
