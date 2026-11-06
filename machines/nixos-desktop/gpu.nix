{ lib, ... }:
let
  kernelDefaultPpFeatureMask = lib.fromHexString "fff7bfff";
  ppOverdriveBit = lib.fromHexString "4000";
in
{
  # The 4K 160 Hz monitor runs on DisplayPort, where this mask changes
  # nothing. 0x400 turns on HDMI 2.1 FRL, which its HDMI input needs for
  # 4K 160 Hz; mainline 7.3 still leaves it off (DC_FRL_MASK in
  # amd_shared.h). 0x2 keeps the multi-monitor bit of the default mask,
  # which 0x400 alone would clear.
  boot.kernelParams = [ "amdgpu.dcfeaturemask=0x402" ];

  hardware.amdgpu.overdrive = {
    enable = true;
    ppfeaturemask =
      "0x" + lib.toLower (lib.toHexString (lib.bitOr kernelDefaultPpFeatureMask ppOverdriveBit));
  };

  # The file is YAML, not services.lact.settings, because the fan curve's keys
  # must be numbers and a Nix attribute name is always a string.
  services.lact.enable = true;
  environment.etc."lact/config.yaml".source = ./lact.yaml;
  systemd.services.lactd.restartTriggers = [ ./lact.yaml ];
}
