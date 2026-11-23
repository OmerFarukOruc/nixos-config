{
  lib,
  pkgs,
  hostSops,
  ...
}:
let
  generatedKeys = [
    "omer-password-hash"
    "root-password-hash"
  ];
  fixtureKeys = lib.concatMap (
    line:
    let
      match = builtins.match "[\"']?([A-Za-z0-9_-]+)[\"']?:.*" line;
    in
    lib.optional (match != null) (lib.head match)
  ) (lib.splitString "\n" (builtins.readFile ../secrets.yaml));
  missingKeys = lib.unique (
    lib.filter (key: !(lib.elem key (generatedKeys ++ fixtureKeys))) (
      map (secret: lib.head (lib.splitString "/" secret.key)) (
        lib.filter (secret: secret.format != "binary" && secret.key != "") (lib.attrValues hostSops.secrets)
      )
    )
  );
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
          ${lib.concatMapStringsSep "\n" (key: ''echo "${key}: '$hash'"'') generatedKeys}
          cat ${../secrets.yaml}
        } > plain.yaml
        sops --encrypt --age "$(ssh-to-age -i $out/ssh_host_ed25519_key.pub)" \
          --input-type yaml --output-type yaml plain.yaml > $out/secrets.yaml
      '';
  fixture =
    lib.throwIf (missingKeys != [ ])
      "ci/server-boot/secrets.yaml lacks ${lib.concatStringsSep ", " missingKeys}, which the host's sops.secrets read; sops-install-secrets installs no secret when one key is missing, so the VM would wait 900 s for its network address and time out"
      "${secrets}/secrets.yaml";
in
{
  sops = {
    validateSopsFiles = false;
    defaultSopsFile = lib.mkForce fixture;
    age.sshKeyPaths = [ "${secrets}/ssh_host_ed25519_key" ];
    secrets = lib.mapAttrs (_: _: { sopsFile = lib.mkForce fixture; }) (
      lib.filterAttrs (
        _: secret: toString secret.sopsFile != toString hostSops.defaultSopsFile
      ) hostSops.secrets
    );
  };
}
