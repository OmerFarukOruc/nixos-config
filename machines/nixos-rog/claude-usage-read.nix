# fedora-desktop's claude-usage reads this host's
# ~/.cache/claude-usage/usage.json over SSH every 10 minutes, so its Claude
# accounts view shows the logins here. Its everyday key has a passphrase that
# no timer can type, so it reads with a key of its own that can only print that
# file: restrict turns off the terminal and every forwarding.
{
  users.users.oruc.openssh.authorizedKeys.keys = [
    ''restrict,command="cat .cache/claude-usage/usage.json" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICuedCmevUgDGUTdW/a5Y21tshbVatceSB32G3qt8wRe claude-usage-read@fedora-desktop''
  ];
}
