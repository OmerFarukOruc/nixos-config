{
  lib,
  appimageTools,
  fetchurl,
}:
let
  pname = "antigravity-hub";
  version = "2.28.1";
  buildId = "6709500728705024";
  src = fetchurl {
    url = "https://storage.googleapis.com/antigravity-public/antigravity-hub/${version}-${buildId}/linux-x64/Antigravity.AppImage";
    hash = "sha512-cNYVtO+BX+uZ0iuyyo7NjRYpcaQrO8DQfsRqE7hkBsCQQGJs2VRmq1kk85/hSOVU5FMo9KtUKkKyg76DUS1MaA==";
  };
  contents = appimageTools.extract { inherit pname version src; };
in
appimageTools.wrapAppImage {
  inherit pname version;
  src = contents;
  executableName = "antigravity";
  extraInstallCommands = ''
    install -Dm644 ${contents}/antigravity.desktop -t $out/share/applications
    substituteInPlace $out/share/applications/antigravity.desktop \
      --replace-fail 'Exec=AppRun --no-sandbox %U' 'Exec=antigravity %U' \
      --replace-fail 'StartupWMClass=Antigravity' 'StartupWMClass=antigravity'
    install -Dm644 ${contents}/usr/share/icons/hicolor/512x512/apps/antigravity.png \
      -t $out/share/icons/hicolor/512x512/apps
  '';
  passthru.releaseFeed = "https://antigravity-hub-auto-updater-974169037036.us-central1.run.app/manifest/latest-x64-linux.yml";

  meta = {
    description = "Antigravity agent desktop app (official)";
    homepage = "https://antigravity.google";
    license = lib.licenses.unfree;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "antigravity";
  };
}
