# zapret2 on Wi-Fi; the profiles are in nixosModules/zapret2.nix.
let
  # The MT7925 card, rog's only network device.
  wifi = "wlp99s0";
in
{
  imports = [ ../../nixosModules/zapret2.nix ];

  oruc.verifyFacts.wifi = wifi;
  services.zapret2.firewall.interfaces = [ wifi ];
}
