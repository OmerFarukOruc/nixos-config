# KVitals, a Plasma panel widget that shows CPU, memory, GPU, temperature,
# battery and network readings from Plasma's own sensors. The widget is QML
# only, so the package copies it into the plasmoid directory.
{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "kvitals";
  version = "3.3.0";

  src = fetchFromGitHub {
    owner = "yassine20011";
    repo = "kvitals";
    tag = "v${finalAttrs.version}";
    hash = "sha256-0MMYebgVREd7M8RBa25Jme3iM+vMJyULf3YrAo5hvqg=";
  };

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    dir=$out/share/plasma/plasmoids/org.kde.plasma.kvitals
    mkdir -p $dir
    cp -r metadata.json contents $dir/
    runHook postInstall
  '';

  meta = {
    description = "Live system vitals in the Plasma panel";
    homepage = "https://github.com/yassine20011/kvitals";
    license = lib.licenses.gpl3Only;
    platforms = lib.platforms.linux;
  };
})
