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

  postPatch = ''
    substituteInPlace contents/ui/models/MetricStore.qml \
      --replace-fail 'import QtQuick' $'import QtQuick\nimport org.kde.kirigami as Kirigami' \
      --replace-fail 'root.config.warningColor, root.config.criticalColor' 'Kirigami.Theme.neutralTextColor, Kirigami.Theme.negativeTextColor'
  '';

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    dir=$out/share/plasma/plasmoids/org.kde.plasma.kvitals
    mkdir -p $dir
    cp -r metadata.json contents $dir/
    runHook postInstall
  '';

  passthru.githubRepo = "yassine20011/kvitals";

  meta = {
    description = "Live system vitals in the Plasma panel";
    homepage = "https://github.com/yassine20011/kvitals";
    license = lib.licenses.gpl3Only;
    platforms = lib.platforms.linux;
  };
})
