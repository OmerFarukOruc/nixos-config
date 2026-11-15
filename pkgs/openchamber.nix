{
  lib,
  appimageTools,
  fetchurl,
}:
let
  pname = "openchamber";
  version = "2.7.2";
  src = fetchurl {
    url = "https://github.com/openchamber/openchamber/releases/download/v${version}/OpenChamber-${version}-linux-x86_64.AppImage";
    hash = "sha512-LjJgz2j9lLXKXLKfyeHraAvbb94DVlUkAwZGsty7L6+7x/6O7pyj2QlpxBi8isEECYvXceQ7jZmoZdZs6LYkNw==";
  };
  contents = appimageTools.extract { inherit pname version src; };
in
appimageTools.wrapAppImage {
  inherit pname version;
  src = contents;
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
