# The platform profiles of nixos-rog. ppd is the power-profiles-daemon name,
# asusd is the name of the AC and DC tunings, and json is the fan-curves.json
# key. cpu-limits.nix and asus.nix keep each profile's numbers and read the
# names from this list.
[
  {
    ppd = "power-saver";
    asusd = "Quiet";
    json = "quiet";
  }
  {
    ppd = "balanced";
    asusd = "Balanced";
    json = "balanced";
  }
  {
    ppd = "performance";
    asusd = "Performance";
    json = "performance";
  }
]
