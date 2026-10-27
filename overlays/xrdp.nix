# nixpkgs builds xrdp without an H.264 encoder, so an RDP session sends
# RemoteFX or plain bitmaps. --enable-x264 adds x264, and xrdp's own gfx.toml
# already prefers H.264 over RemoteFX and x264 over OpenH264, so no setting
# changes. The build fails when libx264 is missing from configure's pkg-config
# check.
_final: prev: {
  xrdp = prev.xrdp.overrideAttrs (old: {
    buildInputs = old.buildInputs ++ [ prev.x264 ];
    configureFlags = old.configureFlags ++ [ "--enable-x264" ];
  });
}
