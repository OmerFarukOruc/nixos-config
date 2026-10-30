{
  lib,
  stdenv,
  fetchFromGitHub,
  autoreconfHook,
  pkg-config,
  makeWrapper,
  pipewire,
  pulseaudio,
  procps,
  coreutils,
  gnugrep,
  gnused,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "pipewire-module-xrdp";
  version = "0.1";

  src = fetchFromGitHub {
    owner = "neutrinolabs";
    repo = "pipewire-module-xrdp";
    tag = "v${finalAttrs.version}";
    hash = "sha256-ZiKVAMAFBkMpZFqrn4hjZZPxdR+sBtcd4W30z8pkdzk=";
  };

  nativeBuildInputs = [
    autoreconfHook
    pkg-config
    makeWrapper
  ];

  buildInputs = [ pipewire ];

  configureFlags = [
    "--with-module-dir=${placeholder "out"}/lib/pipewire-0.3"
    "--with-xdgautostart-dir=${placeholder "out"}/etc/xdg/autostart"
  ];

  # The loader keeps the module in a pw-cli process that outlives the xrdp
  # session, and upstream ships the step that ends the previous one commented
  # out, so every login would add one more.
  postPatch = ''
    substituteInPlace instfiles/load_pw_modules.sh \
      --replace-fail '#PID=' 'PID=' \
      --replace-fail '#if [ -n "$PID" ]; then' 'if [ -n "$PID" ]; then' \
      --replace-fail '#    kill -HUP $PID' '    kill -HUP $PID' \
      --replace-fail '    #fi' '    fi'
  '';

  # pw-cli loads the module into its own process, so it searches
  # PIPEWIRE_MODULE_DIR, which must list this package next to PipeWire's own
  # modules.
  postInstall = ''
    wrapProgram $out/libexec/pipewire-module-xrdp/load_pw_modules.sh \
      --prefix PATH : ${
        lib.makeBinPath [
          pipewire
          pulseaudio
          procps
          coreutils
          gnugrep
          gnused
        ]
      } \
      --set PIPEWIRE_MODULE_DIR $out/lib/pipewire-0.3:${pipewire}/lib/pipewire-0.3
  '';

  meta = {
    description = "PipeWire sink and source that carry sound over an xrdp session";
    homepage = "https://github.com/neutrinolabs/pipewire-module-xrdp";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
})
