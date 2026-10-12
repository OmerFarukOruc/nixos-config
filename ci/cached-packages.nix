# The packages of each host that no public cache builds, because they come
# from this flake's own inputs, overlays or settings. The host-packages-cache
# workflow builds them from the host's own configuration and pushes them to the
# public omerfarukoruc Cachix cache. scripts/auto-update.sh moves the inputs
# they come from only once that cache holds them.
#
# Takes the root flake and returns { <host> = { <pname> = <package>; }; }.
flake:
let
  inherit (flake.inputs.nixpkgs) lib;

  # Free licences only, because the cache is public. whisper-cpp stays out: its
  # CUDA build references unfree NVIDIA libraries, and cachix push uploads a
  # whole closure.
  pnames = [
    "deskflow"
    "dms-shell"
    "kwin-better-blur"
    # The SilentSDDM theme.
    "silent"
    "sops-install-secrets"
  ];

  free =
    p:
    lib.throwIf (p.meta.unfree or true) "${p.name} is unfree, so the public cache must not hold it." p;

  hostPackages =
    config:
    let
      candidates =
        config.environment.systemPackages
        ++ config.home-manager.users.oruc.home.packages
        ++ lib.optional (config ? sops) config.sops.package;
      picked = lib.filter (p: lib.elem (p.pname or null) pnames) candidates;
    in
    lib.listToAttrs (map (p: lib.nameValuePair p.pname (free p)) picked);
in
lib.mapAttrs (_: host: hostPackages host.config) flake.nixosConfigurations
