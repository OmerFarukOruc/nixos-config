# Radeon RX 7900 XTX (Navi 31): display features, overclocking access and
# the fan curve. nixosModules/amd-graphics.nix sets up the drivers.
_: {
  # 0x400 turns on HDMI 2.1 FRL, which the 4K 160 Hz monitor on HDMI-A-1
  # needs; mainline 7.3 still leaves it off (DC_FRL_MASK in amd_shared.h).
  # 0x2 keeps the multi-monitor bit of the default mask, which 0x400 alone
  # would clear.
  boot.kernelParams = [ "amdgpu.dcfeaturemask=0x402" ];

  # Overdrive lets LACT change power, clocks and voltage. The mask is the
  # kernel's default, 0xfff7bfff, plus the overdrive bit 0x4000.
  hardware.amdgpu.overdrive = {
    enable = true;
    ppfeaturemask = "0xfff7ffff";
  };

  # LACT owns the GPU fan. Power, clocks and voltage stay stock. The file is
  # YAML, not services.lact.settings, because the fan curve's keys must be
  # numbers and a Nix attribute name is always a string.
  services.lact.enable = true;
  environment.etc."lact/config.yaml".source = ./lact.yaml;
  systemd.services.lactd.restartTriggers = [ ./lact.yaml ];
}
