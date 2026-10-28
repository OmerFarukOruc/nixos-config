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
    secrets = {
      cloudflare-acme-dns-token.sopsFile = lib.mkForce "${secrets}/secrets.yaml";
      github-update-token.sopsFile = lib.mkForce "${secrets}/secrets.yaml";
      openchamber-ui-password.sopsFile = lib.mkForce "${secrets}/secrets.yaml";
      opencode-server-password.sopsFile = lib.mkForce "${secrets}/secrets.yaml";
      herdr-web-token.sopsFile = lib.mkForce "${secrets}/secrets.yaml";
    }
    //
      lib.genAttrs
        [
          "cliproxy-api-key-omer"
          "cliproxy-api-key-friend"
          "cliproxy-management-key"
          "cliproxy-cloudflare-dns-token"
          "cliproxy-ts-authkey"
          "cliproxy-share-host"
        ]
        (_: {
          sopsFile = lib.mkForce "${secrets}/secrets.yaml";
        });
  };
}
