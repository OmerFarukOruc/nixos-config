# stay-green keeps Omer's Teams status Available through Microsoft Graph
# (https://github.com/OmerFarukOruc/stay-green). The script needs only the
# Python standard library, 3.14 or newer.
{
  python314,
  src,
  stdenvNoCC,
}:
stdenvNoCC.mkDerivation {
  pname = "stay-green";
  version = "0-unstable-${src.lastModifiedDate or "0"}";
  inherit src;
  buildInputs = [ python314 ];
  dontBuild = true;
  installPhase = ''
    install -Dm755 stay-green $out/bin/stay-green
  '';
  # A run outside the schedule reads the schedule and its time zone and ends
  # before any sign-in, so it proves the interpreter and its zoneinfo.
  doInstallCheck = true;
  installCheckPhase = ''
    HOME=$TMPDIR STAY_GREEN_SCHEDULE="Mon 00:00-00:01" STAY_GREEN_TIME_ZONE=Europe/Istanbul \
      $out/bin/stay-green run
  '';
  meta.mainProgram = "stay-green";
}
