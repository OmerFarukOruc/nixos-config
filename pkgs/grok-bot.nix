{
  callPackage,
  fetchurl,
}:
let
  version = "1.1.0";
  src = fetchurl {
    url = "https://downloads.cursor.com/aptrepo/pool/grok-bot/g/gr/grok-bot_${version}_amd64.deb";
    hash = "sha256-WwL7IVED7e2U7J84GnkNcfZyfwF2gcft0bVvK4z6Vy0=";
  };
in
callPackage ./electron-deb {
  pname = "grok-bot";
  inherit version src;
  appDir = "opt/Grok Bot";
  desktopExec = "grok-bot";
  passthru.aptIndex = "https://downloads.cursor.com/aptrepo/dists/grok-bot/main/binary-amd64/Packages";
  meta = {
    description = "Grok Bot desktop agent for Linux (official)";
    homepage = "https://x.ai/bot";
  };
}
