{
  lib,
  pkgs,
  hostSops,
  ...
}:
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
          echo "omer-password-hash: '$hash'"
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
    secrets = lib.mapAttrs (_: _: { sopsFile = lib.mkForce "${secrets}/secrets.yaml"; }) (
      lib.filterAttrs (
        _: secret: toString secret.sopsFile != toString hostSops.defaultSopsFile
      ) hostSops.secrets
    );
  };
}
