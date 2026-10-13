# Claude Desktop, official Linux build, repacked from Anthropic's .deb.
# scripts/update-app.sh moves version and hash to the newest entry of
# passthru.aptIndex.
{
  lib,
  stdenv,
  fetchurl,
  dpkg,
  autoPatchelfHook,
  makeWrapper,
  wrapGAppsHook3,
  alsa-lib,
  at-spi2-atk,
  at-spi2-core,
  atk,
  cairo,
  cups,
  dbus,
  expat,
  gdk-pixbuf,
  glib,
  gtk3,
  libdrm,
  libgbm,
  libGL,
  libxkbcommon,
  nspr,
  nss,
  pango,
  systemd,
  vulkan-loader,
  libnotify,
  libsecret,
  libuuid,
  libappindicator-gtk3,
  libX11,
  libXcomposite,
  libXdamage,
  libXext,
  libXfixes,
  libXrandr,
  libxcb,
  libxshmfence,
  libxcursor,
  libxi,
  libxtst,
  libseccomp,
  libcap_ng,
  pipewire,
}:
stdenv.mkDerivation rec {
  pname = "claude-desktop";
  version = "2.31226.1";

  src = fetchurl {
    url = "https://downloads.claude.ai/claude-desktop/apt/stable/pool/main/c/claude-desktop/claude-desktop_${version}_amd64.deb";
    hash = "sha256-Wpvr38sd9s44dns3Pzp/q/dxVqLd2KP10Elh2lveMF4=";
  };

  nativeBuildInputs = [
    dpkg
    autoPatchelfHook
    makeWrapper
    wrapGAppsHook3
  ];
  buildInputs = [
    alsa-lib
    at-spi2-atk
    at-spi2-core
    atk
    cairo
    cups
    dbus
    expat
    gdk-pixbuf
    glib
    gtk3
    libdrm
    libgbm
    libGL
    libxkbcommon
    nspr
    nss
    pango
    systemd
    vulkan-loader
    libnotify
    libsecret
    libuuid
    libappindicator-gtk3
    libX11
    libXcomposite
    libXdamage
    libXext
    libXfixes
    libXrandr
    libxcb
    libxshmfence
    libxcursor
    libxi
    libxtst
    libseccomp
    libcap_ng
    pipewire
  ];
  runtimeDependencies = [
    (lib.getLib systemd)
    libGL
  ];

  dontConfigure = true;
  dontBuild = true;
  dontWrapGApps = true;

  unpackPhase = "dpkg-deb --fsys-tarfile $src | tar -x --no-same-owner --no-same-permissions";

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin $out/share
    cp -r usr/lib/claude-desktop $out/lib
    cp -r usr/share/. $out/share/
    # chrome-sandbox needs setuid. Without it Electron uses the user-namespace
    # sandbox, so the wrapper passes no --no-sandbox, which would turn that
    # sandbox off.
    rm -f $out/lib/chrome-sandbox
    desktopFiles=("$out"/share/applications/*.desktop)
    if [ ! -f "''${desktopFiles[0]:-}" ]; then
      echo "The .deb has no desktop file in usr/share/applications." >&2
      exit 1
    fi
    for f in "''${desktopFiles[@]}"; do
      substituteInPlace "$f" \
        --replace-quiet "/usr/lib/claude-desktop/claude-desktop" "$out/bin/claude-desktop" \
        --replace-quiet "Exec=claude-desktop" "Exec=$out/bin/claude-desktop"
      # Releases differ in which of the two forms they use, so each replacement
      # may change nothing; every Exec line must point at the wrapper afterwards.
      if grep -E '^(Try)?Exec=' "$f" | grep -qvE "^(Try)?Exec=$out/bin/claude-desktop( |$)"; then
        echo "$f has an Exec line that does not run $out/bin/claude-desktop." >&2
        exit 1
      fi
      grep -q "^Exec=$out/bin/claude-desktop" "$f"
    done
    runHook postInstall
  '';

  # wrapGAppsHook3 fills gappsWrapperArgs in preFixup, so the wrapper comes after it.
  postFixup = ''
    makeWrapper $out/lib/claude-desktop $out/bin/claude-desktop \
      "''${gappsWrapperArgs[@]}" \
      --add-flags "--ozone-platform-hint=auto --enable-features=WaylandWindowDecorations" \
      --prefix LD_LIBRARY_PATH : "${
        lib.makeLibraryPath [
          libGL
          vulkan-loader
        ]
      }"
  '';

  passthru.aptIndex = "https://downloads.claude.ai/claude-desktop/apt/stable/dists/stable/main/binary-amd64/Packages";

  meta = {
    description = "Claude Desktop for Linux (official beta)";
    homepage = "https://claude.ai/download";
    license = lib.licenses.unfree;
    platforms = [ "x86_64-linux" ];
    mainProgram = "claude-desktop";
  };
}
