# Deskflow 1.27.0, which nixpkgs does not have yet. Once nixpkgs' deskflow
# reaches 1.27.0, the version check below passes it through unchanged; then
# delete the version override. Release 1.27.0 drops the evdev.xml path, the
# legacy tests and the user docs that nixpkgs' 1.26.0 build patches, runs and
# installs.
#
# Deskflow shares the clipboard on Wayland only when it builds against
# libportal 0.10.0 or newer, which adds the clipboard API. Without it the
# client never sends what you copy to the server. Only Deskflow gets the newer
# libportal, so nothing else rebuilds. Once nixpkgs' libportal reaches 0.10.0
# the override passes it through; then delete it. The build drops the
# clipboard code without an error when libportal lacks that API, so the install
# check fails the build instead.
final: prev:
let
  libportal =
    if final.lib.versionAtLeast prev.libportal.version "0.10.0" then
      prev.libportal
    else
      prev.libportal.overrideAttrs (_old: {
        version = "0.10.0";
        src = final.fetchFromGitHub {
          owner = "flatpak";
          repo = "libportal";
          tag = "0.10.0";
          hash = "sha256-vU3jnHxCvxZMSJOh5hzkCB8uuE0NnbnZM7+eQ6a5+oI=";
        };
        # 0.10.0 already contains nixpkgs' Qt 6.9 patch.
        patches = [ ];
      });
  withLibportal = prev.deskflow.override { inherit libportal; };
  deskflow =
    if final.lib.versionAtLeast withLibportal.version "1.27.0" then
      withLibportal
    else
      withLibportal.overrideAttrs (_old: {
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
          ctest --test-dir "src/unittests" --output-on-failure --parallel 1 \
            --exclude-regex "OSX(KeyState|Clipboard)Tests"
          runHook postCheck
        '';
        postInstall = "";
      });
in
{
  deskflow = deskflow.overrideAttrs {
    doInstallCheck = true;
    installCheckPhase = ''
      runHook preInstallCheck
      grep -rqa xdp_session_request_clipboard "$out/bin" || {
        echo "deskflow was built without Wayland clipboard support" >&2
        exit 1
      }
      runHook postInstallCheck
    '';
  };
}
