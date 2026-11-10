{
  lib,
  stdenv,
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
  libsecret,
  libxkbcommon,
  nspr,
  nss,
  pango,
  systemd,
  vulkan-loader,
  libX11,
  libXcomposite,
  libXdamage,
  libXext,
  libXfixes,
  libXrandr,
  libxcb,
  pname,
  version,
  src,
  appDir,
  desktopExec,
  extraNativeBuildInputs ? [ ],
  extraBuildInputs ? [ ],
  postInstall ? "",
  passthru,
  meta,
}:
stdenv.mkDerivation {
  inherit
    pname
    version
    src
    postInstall
    passthru
    ;

  nativeBuildInputs = [
    dpkg
    autoPatchelfHook
    makeWrapper
    wrapGAppsHook3
  ]
  ++ extraNativeBuildInputs;
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
    libxkbcommon
    nspr
    nss
    pango
    stdenv.cc.cc.lib
    systemd
    vulkan-loader
    libX11
    libXcomposite
    libXdamage
    libXext
    libXfixes
    libXrandr
    libxcb
  ]
  ++ extraBuildInputs;
  runtimeDependencies = [
    (lib.getLib systemd)
    libGL
    libnotify
    libpulseaudio
    libsecret
  ];

  dontConfigure = true;
  dontBuild = true;
  dontWrapGApps = true;

  unpackPhase = "dpkg-deb --fsys-tarfile $src | tar -x --no-same-owner --no-same-permissions";

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin $out/lib $out/share
    cp -r ${lib.escapeShellArg appDir} $out/lib/${pname}
    cp -r usr/share/. $out/share/
    substituteInPlace $out/share/applications/${pname}.desktop \
      --replace-fail ${lib.escapeShellArg "Exec=${desktopExec}"} "Exec=$out/bin/${pname}"
    if grep -E '^(Try)?Exec=' $out/share/applications/${pname}.desktop | grep -qvE "^(Try)?Exec=$out/bin/${pname}( |$)"; then
      echo "${pname}.desktop has an Exec line that does not run $out/bin/${pname}." >&2
      exit 1
    fi
    runHook postInstall
  '';

  # wrapGAppsHook3 fills gappsWrapperArgs in preFixup, so the wrapper comes after it.
  postFixup = ''
    makeWrapper $out/lib/${pname}/${pname} $out/bin/${pname} \
      "''${gappsWrapperArgs[@]}" \
      --add-flags "--ozone-platform-hint=auto --enable-features=WaylandWindowDecorations" \
      --prefix LD_LIBRARY_PATH : "${
        lib.makeLibraryPath [
          libGL
          vulkan-loader
        ]
      }"
  '';

  meta = {
    license = lib.licenses.unfree;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
    mainProgram = pname;
  }
  // meta;
}
