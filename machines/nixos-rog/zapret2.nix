let
  wifi = "wlp99s0";
in
{
  imports = [ ../../nixosModules/zapret2.nix ];

  oruc.verifyFacts.wifi = wifi;
  services.zapret2.firewall.interfaces = [ wifi ];
}
