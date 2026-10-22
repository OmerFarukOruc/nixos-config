# Antigravity, Google's agent desktop app, the official Linux AppImage.
# scripts/update-app.sh moves version and hash to the newest release in
# passthru.releaseFeed, the electron-builder feed the app's own updater reads.
# The download URL also embeds a build ID, and update-app.sh moves it.
{
  lib,
  appimageTools,
  fetchurl,
}:
let
  pname = "antigravity-hub";
  version = "2.25.0";
  buildId = "6535192714805248";
  src = fetchurl {
    url = "https://storage.googleapis.com/antigravity-public/antigravity-hub/${version}-${buildId}/linux-x64/Antigravity.AppImage";
    hash = "sha512-zxtCJnQDYAaPN2Cmc5Fmm7mrt9B0FI2X8mhUP+XSRrIlw2VvbONXZAZIi2AZpl8f86w5DPnzuoZXaIHkrE3qlg==";
  };
  contents = appimageTools.extract { inherit pname version src; };
in
appimageTools.wrapAppImage {
  inherit pname version;
  src = contents;
  executableName = "antigravity";
  # Google sign-in returns to the app through antigravity:// links. The window
  # class is lower case, unlike the StartupWMClass the AppImage ships.
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
