{
  callPackage,
  fetchurl,
}:
let
  version = "0.79.4";
  src = fetchurl {
    url = "https://downloads.cursor.com/aptrepo/pool/grok-bot/g/gr/grok-bot_${version}_amd64.deb";
    hash = "sha256-zw/QAyJJzwjnX23/BFdmtRlQeN2HjR7u1gpoxNMaelo=";
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
