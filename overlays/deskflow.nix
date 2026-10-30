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
in
{
  deskflow = withLibportal.overrideAttrs {
    # LoggerTests and ComputerTests both rewrite tmp/test/Deskflow.conf in the
    # same directory, so ctest must run them one at a time.
    enableParallelChecking = false;
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
