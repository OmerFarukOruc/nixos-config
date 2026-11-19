{ lib, ... }:
{
  # disko's makeDiskoTest starts the booted VM with 1024 MB
  # (create_test_machine in its lib/tests.nix), which the two Grok Bot apps do
  # not fit in.
  oruc.machine.features.grokBotBox = lib.mkForce false;
}
