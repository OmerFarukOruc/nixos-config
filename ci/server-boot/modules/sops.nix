# The sops file of the test machine holds test values under the real key names.
# They are encrypted for the age key of an SSH key that this build makes,
# because the box's own host key is not in the build. sops-nix reads that key as
# it reads the host key, so the real activation runs (password hashes, the
# network template). The network values are those of QEMU's user networking.
# Put the values of a new key in ../secrets.yaml.
{ lib, pkgs, ... }:
let
  secrets =
    pkgs.runCommand "server-boot-secrets"
      {
        nativeBuildInputs = [
          pkgs.mkpasswd
          pkgs.openssh
          pkgs.sops
          pkgs.ssh-to-age
        ];
      }
      ''
        mkdir $out
        ssh-keygen -q -t ed25519 -N "" -f $out/ssh_host_ed25519_key
        hash=$(mkpasswd -m sha-512 test)
        {
          echo "oruc-password-hash: '$hash'"
          echo "root-password-hash: '$hash'"
          cat ${../secrets.yaml}
        } > plain.yaml
        sops --encrypt --age "$(ssh-to-age -i $out/ssh_host_ed25519_key.pub)" \
          --input-type yaml --output-type yaml plain.yaml > $out/secrets.yaml
      '';
in
{
  sops = {
    validateSopsFiles = false;
    defaultSopsFile = lib.mkForce "${secrets}/secrets.yaml";
    age.sshKeyPaths = [ "${secrets}/ssh_host_ed25519_key" ];
    # The Cloudflare token has its own sops file on the box.
    secrets.cloudflare-acme-dns-token.sopsFile = lib.mkForce "${secrets}/secrets.yaml";
  };
}
