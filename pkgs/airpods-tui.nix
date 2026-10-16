{
  lib,
  rustPlatform,
  fetchFromGitHub,
  pkg-config,
  dbus,
  libpulseaudio,
}:
rustPlatform.buildRustPackage (finalAttrs: {
  pname = "airpods-tui";
  version = "0.3.3";

  src = fetchFromGitHub {
    owner = "annoyedmilk";
    repo = "airpods-tui";
    tag = "v${finalAttrs.version}";
    hash = "sha256-WHC0UDPCGdAqFt9mgSJxTiKraL2FoYIlvvCZp+sg+1o=";
  };

  cargoHash = "sha256-Buf5wPQ8fPAimMd49rNkgPcA6a6rYsagFZ62E8bzpzw=";

  nativeBuildInputs = [ pkg-config ];
  buildInputs = [
    dbus
    libpulseaudio
  ];
  # These tests start a session dbus-daemon, which finds no session.conf in
  # the build sandbox.
  checkFlags = [ "--skip=bluez_tests::" ];

  meta = {
    description = "Terminal UI and daemon for AirPods over Apple's AACP control channel";
    homepage = "https://github.com/annoyedmilk/airpods-tui";
    license = lib.licenses.gpl3Plus;
    mainProgram = "airpods-tui";
    platforms = lib.platforms.linux;
  };
})
