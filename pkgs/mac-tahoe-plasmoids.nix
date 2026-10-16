# The QML parts of the macOS Tahoe Plasma theme that its own packages leave
# out: the fullscreen launcher, and the icons-only variant of its dock task
# manager. The variant is only metadata whose X-Plasma-RootPath points at the
# compiled task manager, as Plasma's own icontasks does. src is the mac-tahoe
# flake input.
{
  lib,
  stdenvNoCC,
  src,
}:
stdenvNoCC.mkDerivation {
  pname = "mac-tahoe-plasmoids";
  version = lib.strings.trim (builtins.readFile "${src}/VERSION");
  inherit src;

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    dir=$out/share/plasma/plasmoids
    mkdir -p $dir
    cp -r src/offline/plasmoids/org.kde.mac-tahoe-liquid-kde.launcher \
      src/offline/plasmoids/org.kde.mac.tahoe.liquid.icontasks $dir/
    runHook postInstall
  '';

  meta = {
    description = "Launcher and icons-only dock of the macOS Tahoe Plasma theme";
    homepage = "https://github.com/lestercorderomurillo/macos-tahoe-liquid-kde";
    # The licence that both metadata.json files name.
    license = lib.licenses.gpl3Only;
    platforms = lib.platforms.linux;
  };
}
