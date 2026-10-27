# ChatGPT, OpenAI's official Linux build, repacked from its .deb.
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
  libnotify,
  libpulseaudio,
  libusb1,
  libxkbcommon,
  nspr,
  nss,
  openssl,
  pango,
  systemd,
  tpm2-tss,
  vulkan-loader,
  libX11,
  libXcomposite,
  libXdamage,
  libXext,
  libXfixes,
  libXrandr,
  libxcb,
  nodejs_24,
}:
stdenv.mkDerivation rec {
  pname = "chatgpt";
  version = "26.1023.50603";

  src = fetchurl {
    url = "https://persistent.oaistatic.com/codex-app-prod/linux/deb/pool/main/c/chatgpt/chatgpt_${version}_amd64.deb";
    hash = "sha256-9cm/Lwo9UME5F69hGFp5H1IOWDmQn+qCLYhr41sSGyY=";
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
    libnotify
    libusb1
    libxkbcommon
    nspr
    nss
    openssl
    pango
    stdenv.cc.cc.lib
    systemd
    tpm2-tss
    vulkan-loader
    libX11
    libXcomposite
    libXdamage
    libXext
    libXfixes
    libXrandr
    libxcb
  ];
  # Loaded with dlopen, so autoPatchelf does not see them.
  runtimeDependencies = [
    (lib.getLib systemd)
    libGL
    libnotify
    libpulseaudio
  ];
  # The Qt shims load only inside a Qt desktop that asks for them, and the
  # musl builds of the bundled node-hid and serialport only on a musl system.
  autoPatchelfIgnoreMissingDeps = [
    "libQt5*"
    "libQt6*"
    "libc.musl-x86_64.so.1"
  ];

  dontConfigure = true;
  dontBuild = true;
  dontWrapGApps = true;

  unpackPhase = "dpkg-deb --fsys-tarfile $src | tar -x --no-same-owner --no-same-permissions";

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin $out/lib $out/share
    cp -r usr/lib/chatgpt $out/lib/chatgpt
    cp -r usr/share/. $out/share/
    # autoPatchelf gives the bundled Node, the official Linux build, a program
    # header that overlaps the next segment, so it crashes in ld.so before
    # main. nixpkgs' Node of the same major version runs the plugins instead;
    # autoPatchelf skips the symlink.
    node=$out/lib/chatgpt/resources/cua_node
    grep -Eq '"node_binary_version": *"24\.' $node/manifest.json || {
      echo "chatgpt: the bundled Node is no longer major version 24; change nodejs_24" >&2
      exit 1
    }
    ln -sf ${lib.getExe nodejs_24} $node/bin/node
    substituteInPlace $out/share/applications/chatgpt.desktop \
      --replace-fail "Exec=chatgpt" "Exec=$out/bin/chatgpt"
    # Only its own codex:// links: the .deb also claims web links and office files.
    sed -i 's|^MimeType=.*|MimeType=x-scheme-handler/codex;|' $out/share/applications/chatgpt.desktop
    grep -qx 'MimeType=x-scheme-handler/codex;' $out/share/applications/chatgpt.desktop
    runHook postInstall
  '';

  # wrapGAppsHook3 fills gappsWrapperArgs in preFixup, so the wrapper comes after it.
  postFixup = ''
    makeWrapper $out/lib/chatgpt/ChatGPT $out/bin/chatgpt \
      "''${gappsWrapperArgs[@]}" \
      --add-flags "--ozone-platform-hint=auto --enable-features=WaylandWindowDecorations" \
      --prefix LD_LIBRARY_PATH : "${
        lib.makeLibraryPath [
          libGL
          vulkan-loader
        ]
      }"
  '';

  passthru.aptIndex = "https://persistent.oaistatic.com/codex-app-prod/linux/deb/dists/stable/main/binary-amd64/Packages";

  meta = {
    description = "ChatGPT for Linux (official)";
    homepage = "https://developers.openai.com/codex/app";
    license = lib.licenses.unfree;
    platforms = [ "x86_64-linux" ];
    mainProgram = "chatgpt";
  };
}
