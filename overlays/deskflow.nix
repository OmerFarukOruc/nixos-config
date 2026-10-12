# Deskflow 1.27.0, which nixpkgs does not have yet. Once nixpkgs' deskflow
# reaches 1.27.0 this overlay passes it through unchanged; then delete the file.
# Release 1.27.0 drops the evdev.xml path, the legacy tests and the user docs
# that nixpkgs' 1.26.0 build patches, runs and installs.
final: prev: {
  deskflow =
    if final.lib.versionAtLeast prev.deskflow.version "1.27.0" then
      prev.deskflow
    else
      prev.deskflow.overrideAttrs (_old: {
        version = "1.27.0";
        src = final.fetchFromGitHub {
          owner = "deskflow";
          repo = "deskflow";
          tag = "v1.27.0";
          hash = "sha256-CgmK/2MbxUJD16q/WdJHz4ppWsMvxIxuwZ8nIgWoH/4=";
        };
        postPatch = ''
          substituteInPlace deploy/linux/deploy.cmake \
            --replace-fail 'message(FATAL_ERROR "Unable to read file /etc/os-release")' 'set(RELEASE_FILE_CONTENTS "")'
          substituteInPlace translations/CMakeLists.txt \
            --replace-fail 'PATHS ''${QT_ROOT_DIR} PATH_SUFFIXES "translations" "share/qt/translations"' 'PATHS "${final.qt6.qttranslations}/translations"'
          substituteInPlace src/lib/net/CMakeLists.txt \
            --replace-fail "set(OPENSSL_USE_STATIC_LIBS TRUE)" ""
        '';
        checkPhase = ''
          runHook preCheck
          export QT_QPA_PLATFORM=offscreen
          ctest --test-dir "src/unittests" --output-on-failure \
            --exclude-regex "OSX(KeyState|Clipboard)Tests"
          runHook postCheck
        '';
        postInstall = "";
      });
}
