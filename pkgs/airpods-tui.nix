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

  # Upstream powers the adapter on at daemon start and exits when that fails,
  # as under nixos-latitude's rfkill block. The radio stays with the desktop.
  # The daemon then waits for a connection. Its BLE scan, which reports the
  # AirPods while they sit in the case, ends once it finds the adapter off, at
  # start or later, until the daemon restarts.
  postPatch = ''
    substituteInPlace src/main.rs --replace-fail \
      "    adapter.set_powered(true).await?;" ""
  '';

  nativeBuildInputs = [ pkg-config ];
  buildInputs = [
    dbus
    libpulseaudio
  ];
  checkFlags = [ "--skip=bluez_tests::" ];

  meta = {
    description = "Terminal UI and daemon for AirPods over Apple's AACP control channel";
    homepage = "https://github.com/annoyedmilk/airpods-tui";
    license = lib.licenses.gpl3Plus;
    mainProgram = "airpods-tui";
    platforms = lib.platforms.linux;
  };
})
