# The packages of each host that no public cache builds, because they come
# from this flake's own inputs, overlays or settings. The host-packages-cache
# workflow builds them from the host's own configuration and pushes them to the
# public omerfarukoruc Cachix cache. scripts/auto-update.sh moves the inputs
# they come from once that cache holds them, or after a day without them.
#
# Takes the root flake and returns { <host> = { <pname> = <package>; }; }.
flake:
let
  inherit (flake.inputs.nixpkgs) lib;

  # Free licences only, because the cache is public. whisper-cpp stays out: its
  # CUDA build references unfree NVIDIA libraries, and cachix push uploads a
  # whole closure.
  pnames = [
    "airpods-tui"
    "deskflow"
    "dms-shell"
    "glass-qt6"
    # pkgs/herdr.nix, until llm-agents packages its version; it leaves with that file.
    "herdr"
    "kwin-glass"
    # The dock's task manager, from the macOS Tahoe theme.
    "mac-tahoe-task-manager"
    # The login screen theme.
    "sddm-astronaut"
    # The lock screen's video wallpaper plugin.
    "smart-video-wallpaper"
    "sops-install-secrets"
  ];

  # Free libraries that a listed package links and that only this flake
  # builds, such as the newer libportal of overlays/deskflow.nix. The package
  # in the cache is of no use while its closure is incomplete there.
  # These names are selected from direct buildInputs and propagatedBuildInputs
  # only. ci/host-packages.sh checks the recursive runtime closure and refuses
  # to push an unlisted path that cache.nixos.org lacks. A dependency deeper in
  # that closure needs an explicit source here; the global pkgs.libportal is
  # not Deskflow's private override.
  dependencies = [ "libportal" ];

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
      inputs = lib.concatMap (p: p.buildInputs or [ ] ++ p.propagatedBuildInputs or [ ]) picked;
      deps = lib.filter (d: lib.elem (d.pname or null) dependencies) inputs;
    in
    lib.listToAttrs (map (p: lib.nameValuePair p.pname (free p)) (picked ++ deps));

  hosts = lib.mapAttrs (_: host: hostPackages host.config) flake.nixosConfigurations;
  # A renamed package would otherwise drop out of the cache without a sign.
  lost = lib.subtractLists (lib.concatMap lib.attrNames (lib.attrValues hosts)) (
    pnames ++ dependencies
  );
in
lib.throwIf (lost != [ ])
  "No host has a package named ${lib.concatStringsSep ", " lost}; update ci/cached-packages.nix."
  hosts
