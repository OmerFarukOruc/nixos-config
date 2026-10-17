# OpenChamber desktop, the official Linux AppImage from GitHub releases.
# scripts/update-app.sh moves version and hash to the newest release in
# passthru.releaseFeed, the electron-builder feed the app's own updater reads.
{
  lib,
  appimageTools,
  fetchurl,
}:
let
  pname = "openchamber";
  version = "2.4.0";
  src = fetchurl {
    url = "https://github.com/openchamber/openchamber/releases/download/v${version}/OpenChamber-${version}-linux-x86_64.AppImage";
    hash = "sha512-UhO/EmPYRUUTR1hnceGg+9HpAYGlhbCjWEwazGT+rPcpBw/Wg7kpBE4tbUScTT9FXSx80hbpd82N4/wUZt3gyQ==";
  };
  contents = appimageTools.extract { inherit pname version src; };
in
appimageTools.wrapAppImage {
  inherit pname version;
  src = contents;
  # Pairing links (openchamber://connect) open in the app.
  extraInstallCommands = ''
    install -Dm644 ${contents}/openchamber.desktop -t $out/share/applications
    substituteInPlace $out/share/applications/openchamber.desktop \
      --replace-fail 'Exec=AppRun --no-sandbox %U' 'Exec=openchamber %U'
    echo 'MimeType=x-scheme-handler/openchamber;' >>$out/share/applications/openchamber.desktop
    install -Dm644 ${contents}/usr/share/icons/hicolor/512x512/apps/openchamber.png \
      -t $out/share/icons/hicolor/512x512/apps
  '';
  passthru.releaseFeed = "https://github.com/openchamber/openchamber/releases/latest/download/latest-linux.yml";

  meta = {
    description = "OpenChamber desktop app for OpenCode (official)";
    homepage = "https://github.com/openchamber/openchamber";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "openchamber";
  };
}
