# nixpkgs builds xrdp without an H.264 encoder, so an RDP session sends
# RemoteFX or plain bitmaps. --enable-x264 adds x264, and xrdp's own gfx.toml
# already prefers H.264 over RemoteFX and x264 over OpenH264, so no setting
# changes. The build fails when libx264 is missing from configure's pkg-config
# check.
#
# xrdp 0.10.6.1 has no map for the Turkish Q layout (RDP layout 0x041F), so
# the session of a Turkish client got the us layout. The two patches are the
# change that adds it on xrdp's v0.10 branch after that release
# (https://github.com/neutrinolabs/xrdp/pull/3875); preConfigure runs
# ./bootstrap, so the Makefile.am change takes effect.
_final: prev: {
  xrdp = prev.xrdp.overrideAttrs (old: {
    buildInputs = old.buildInputs ++ [ prev.x264 ];
    configureFlags = old.configureFlags ++ [ "--enable-x264" ];
    patches = (old.patches or [ ]) ++ [
      (prev.fetchpatch {
        url = "https://github.com/neutrinolabs/xrdp/commit/aceaae225536b6613795c1b4fc3477dcbea17951.patch";
        hash = "sha256-KIT5jsqVLhVywBeW9tP25TiBZluANNy84LOdHrG57Vo=";
      })
      (prev.fetchpatch {
        url = "https://github.com/neutrinolabs/xrdp/commit/310a124e69ef937f7551cad507d4acede887c414.patch";
        hash = "sha256-cGdeAqMx42P4pgu+U+6Sg+cXuXM95GzLZP9LIiLY8yA=";
      })
    ];
  });
}
