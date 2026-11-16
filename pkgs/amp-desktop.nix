{
  asar,
  callPackage,
  fetchurl,
  libuuid,
  libXScrnSaver,
  libXtst,
}:
let
  version = "0.1.29913241";
  src = fetchurl {
    url = "https://static.ampcode.com/linux/${version}/amp-desktop-${version}-amd64.deb";
    hash = "sha256-icC9T/Ho+A4ypBZNe8rxdPy2fu5nFTLv+xWI5ErgbaY=";
  };
in
callPackage ./electron-deb {
  pname = "amp-desktop";
  inherit version src;
  appDir = "opt/amp";
  desktopExec = "/opt/amp/amp-desktop";
  extraNativeBuildInputs = [ asar ];
  extraBuildInputs = [
    libuuid
    libXScrnSaver
    libXtst
  ];
  postInstall = ''
    resources=$out/lib/amp-desktop/resources
    asar extract $resources/app.asar app
    substituteInPlace app/dist/main.js --replace-fail "  process.execPath," '  "amp-desktop",'
    asar pack app $resources/app.asar
  '';
  passthru.aptIndex = "https://static.ampcode.com/linux/dists/stable/main/binary-amd64/Packages";
  meta = {
    description = "Amp desktop app for Linux (official)";
    homepage = "https://ampcode.com";
  };
}
