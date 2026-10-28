{
  python314,
  src,
  stdenvNoCC,
}:
stdenvNoCC.mkDerivation {
  pname = "stay-green";
  version = "0-unstable-${builtins.substring 0 8 (src.lastModifiedDate or "0")}";
  inherit src;
  buildInputs = [ python314 ];
  dontBuild = true;
  installPhase = ''
    install -Dm755 stay-green $out/bin/stay-green
  '';
  doInstallCheck = true;
  installCheckPhase = ''
    day=$(date -u -d "+2 days" +%a)
    HOME=$TMPDIR STAY_GREEN_SCHEDULE="$day 00:00-23:59" STAY_GREEN_TIME_ZONE=Europe/Istanbul \
      $out/bin/stay-green run
  '';
  meta.mainProgram = "stay-green";
}
