{
  lib,
  stdenv,
  fetchFromGitHub,
  cmake,
  extra-cmake-modules,
  gettext,
  qtbase,
  qtdeclarative,
  qtmultimedia,
  ki18n,
  kcmutils,
  knighttime,
  libplasma,
  plasma5support,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "smart-video-wallpaper";
  version = "2.16.0";

  src = fetchFromGitHub {
    owner = "luisbocanegra";
    repo = "plasma-smart-video-wallpaper-reborn";
    tag = "v${finalAttrs.version}";
    hash = "sha256-Ao1hBIt0VWhwJV6VTvjDKsHYNXyAR7yzHka3EF2dWOo=";
  };

  nativeBuildInputs = [
    cmake
    extra-cmake-modules
    gettext
  ];

  buildInputs = [
    qtbase
    qtdeclarative
    ki18n
    kcmutils
    knighttime
    libplasma
  ];

  # The wallpaper's QML imports these at runtime. The lock screen greeter's own
  # wrapper lacks them, so they reach it through the user profile, which is on
  # the session's QML import path.
  propagatedUserEnvPkgs = [
    qtmultimedia
    plasma5support
  ];

  dontWrapQtApps = true;

  meta = {
    description = "Plasma wallpaper plugin that plays videos on the desktop and lock screen";
    homepage = "https://github.com/luisbocanegra/plasma-smart-video-wallpaper-reborn";
    license = lib.licenses.gpl2Plus;
    platforms = lib.platforms.linux;
  };
})
