# OpenChamber desktop, the official Linux AppImage from GitHub releases.
# scripts/update-app.sh moves version and hash to the newest release in
# passthru.releaseFeed, the electron-builder feed the app's own updater reads.
{
  lib,
  appimageTools,
  fetchurl,
  python3,
}:
let
  pname = "openchamber";
  version = "2.3.2";
  src = fetchurl {
    url = "https://github.com/openchamber/openchamber/releases/download/v${version}/OpenChamber-${version}-linux-x86_64.AppImage";
    hash = "sha512-79bZca8bsgGoTlap3Wzf/HFS7YyWMJ+6fOXHwXiWYeIgOySRKK83m/y5bERpDTnSCe5xOJf8zkQPEaPPXrufjQ==";
  };
  contents = appimageTools.extract {
    inherit pname version src;
    # Save as image on a chat message titled the save dialog with the image's
    # whole data: URL; the patch downloads it through a blob: URL instead.
    postExtract = ''
      ${lib.getExe python3} ${./openchamber-image-export.py} $out/resources/web-dist/assets
    '';
  };
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
