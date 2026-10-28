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

  # The theme dropped the launcher's power button (lock, log out, restart,
  # shut down) from the search bar, but kept SessionButtons.qml and its
  # showSessionActionsButton setting; this puts it back where TahoeLauncher has it.
  postPatch = ''
    substituteInPlace src/offline/plasmoids/org.kde.mac-tahoe-liquid-kde.launcher/contents/ui/SearchBar.qml \
      --replace-fail 'import org.kde.kirigami as Kirigami' 'import org.kde.kirigami as Kirigami
    import org.kde.plasma.plasmoid' \
      --replace-fail '    MenuButton {' '    SessionButtons {
            visible: Plasmoid.configuration.showSessionActionsButton
        }

        MenuButton {'
  '';

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
    # Both metadata.json files name GPL-3.0. The launcher comes from
    # EliverLara/TahoeLauncher, which is GPL-2.0 or later.
    license = [
      lib.licenses.gpl2Plus
      lib.licenses.gpl3Only
    ];
    platforms = lib.platforms.linux;
  };
}
