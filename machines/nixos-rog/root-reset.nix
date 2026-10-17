# Every boot starts from an empty root subvolume. The initrd moves the last
# root to @old-roots and puts a new, empty @nixos in its place. /home, /nix and
# /var/log are subvolumes of their own and stay; every path in
# oruc.keptPaths comes from @nixos-keep through a bind mount.
#
# Before the first boot with this module, scripts/root-reset-seed.sh creates
# @nixos-keep and copies the kept paths into it. Until it has run, the initrd
# leaves @nixos alone. After that, each activation copies a newly kept path
# before its bind mount starts. A deploy with the boot action does not
# activate, so before rebooting into one that adds a kept path, run the seed
# script again.
{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  inherit (config.fileSystems."/") device;
  deviceUnit = "${utils.escapeSystemdPath device}.device";
  kept = lib.unique config.oruc.keptPaths;

  # The initrd swaps the subvolumes on the top level of the btrfs file system.
  # With oruc.root-reset=previous on the kernel command line, it puts the
  # root that the last reset moved away back instead of an empty one.
  resetScript = ''
    top=/run/root-reset
    mkdir -p "$top"
    mount -t btrfs -o subvolid=5 ${device} "$top"
    trap 'cd /; umount "$top"' EXIT
    cd "$top"

    # A power loss between the two renames below leaves only @nixos-new,
    # which is already the empty root, and .last already names the old one.
    if [[ ! -e @nixos && -d @nixos-new ]]; then
      mv @nixos-new @nixos
      echo "root-reset: finished the reset that a power loss interrupted"
      exit 0
    fi
    if [[ ! -d @nixos ]] || ! btrfs subvolume show @nixos >/dev/null 2>&1; then
      echo "root-reset: no @nixos subvolume, nothing to do"
      exit 0
    fi
    if [[ ! -e @nixos-keep/.oruc-seeded ]]; then
      echo "root-reset: @nixos-keep is not seeded, keeping @nixos"
      exit 0
    fi

    mkdir -p @old-roots
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    while [[ -e @old-roots/$stamp ]]; do stamp=$stamp-1; done

    # @old-roots/.last names the root the last reset moved away. The stamps
    # come from the RTC, which another OS may set to local time, so their
    # order cannot pick it.
    if [[ " $(</proc/cmdline) " == *" oruc.root-reset=previous "* ]]; then
      previous=
      [[ -f @old-roots/.last ]] && previous=@old-roots/$(<@old-roots/.last)
      if [[ -z $previous || ! -d $previous ]]; then
        echo "root-reset: no old root to go back to, keeping @nixos"
        exit 0
      fi
      mv @nixos "@old-roots/$stamp-replaced"
      if ! mv "$previous" @nixos; then
        mv "@old-roots/$stamp-replaced" @nixos
        exit 1
      fi
      echo "root-reset: booting $previous; the root it replaced is @old-roots/$stamp-replaced"
      exit 0
    fi

    btrfs subvolume delete @nixos-new >/dev/null 2>&1 || true
    btrfs subvolume create @nixos-new
    echo "$stamp" >@old-roots/.last
    if ! mv @nixos "@old-roots/$stamp"; then
      btrfs subvolume delete @nixos-new
      exit 1
    fi
    if ! mv @nixos-new @nixos; then
      mv "@old-roots/$stamp" @nixos
      exit 1
    fi
    echo "root-reset: the last root is @old-roots/$stamp"
  '';

  # Copies each kept path that the keep directory lacks from the live root,
  # leaving out file systems mounted below it, btrfs subvolumes included. A copy that fails halfway stays
  # under .partial, so a rerun copies again.
  keepCopy = pkgs.writeShellApplication {
    name = "oruc-keep-copy";
    text = ''
      keep=$1
      while IFS= read -r path; do
        [[ -n $path && ! -e $keep$path ]] || continue
        if [[ ! -e $path ]]; then
          # A service creates this directory on its first start.
          mkdir -p "$keep$path"
          echo "empty   $path"
          continue
        fi
        mkdir -p "$keep$(dirname "$path")"
        rm -rf "$keep$path.partial"
        cp -a -x --reflink=auto "$path" "$keep$path.partial"
        mv "$keep$path.partial" "$keep$path"
        echo "copied  $path"
      done <"$2"
    '';
  };

  bindMount = path: {
    name = path;
    value = {
      device = "/keep${path}";
      fsType = "none";
      options = [ "bind" ];
      depends = [ "/keep" ];
      # Mounted in the initrd, so the path exists before anything reads it.
      neededForBoot = true;
    };
  };
in
{
  oruc.keptPaths = [
    "/etc/machine-id"
    # The UID and GID maps that own the files on /home.
    "/var/lib/nixos"
    # The stamps of Persistent timers; without them every such timer, and
    # auto-update with it, runs at each boot.
    "/var/lib/systemd/timers"
    # Screen brightness and the radio kill switches, as last set.
    "/var/lib/systemd/backlight"
    "/var/lib/systemd/rfkill"
    # The state of services with a DynamicUser, such as zapret2. systemd
    # wants this directory at mode 0700, so it is kept whole.
    "/var/lib/private"
  ];

  # sops decrypts with the SSH host key, so the key must survive a reset.
  assertions = [
    {
      assertion = lib.all (
        key: lib.any (path: key == path || lib.hasPrefix "${path}/" key) kept
      ) config.sops.age.sshKeyPaths;
      message = "root-reset.nix: sops.age.sshKeyPaths must lie inside oruc.keptPaths.";
    }
  ];

  # This unit takes any mount on /etc/machine-id for a temporary one and
  # fails on the kept bind mount, whose file is already on disk.
  systemd.suppressedSystemUnits = [ "systemd-machine-id-commit.service" ];

  fileSystems = lib.listToAttrs (map bindMount kept);

  # oruc has no declared password, so a new root would leave the account
  # locked. The seed script copies its password hash here.
  users.users.oruc.hashedPasswordFile = "/keep/secrets/oruc-password";

  boot.initrd.systemd.services.root-reset = {
    description = "Replace the root subvolume with an empty one";
    wantedBy = [ "initrd.target" ];
    requires = [ deviceUnit ];
    after = [ deviceUnit ];
    before = [ "sysroot.mount" ];
    unitConfig.DefaultDependencies = false;
    serviceConfig.Type = "oneshot";
    script = resetScript;
  };

  # A boot entry per generation that goes back to the root of the boot before.
  specialisation.previous-root.configuration.boot.kernelParams = [ "oruc.root-reset=previous" ];

  # Deletes old roots after 30 days. Turn it on once the previous-root entry
  # has booted and the first boot after a reset has passed its checks.
  systemd.services.root-reset-prune = {
    enable = false;
    description = "Delete old roots older than 30 days";
    startAt = "daily";
    path = [
      pkgs.btrfs-progs
      pkgs.util-linux
    ];
    serviceConfig = {
      Type = "oneshot";
      PrivateMounts = true;
    };
    script = ''
      top=$(mktemp -d)
      mount -t btrfs -o subvolid=5 ${device} "$top"
      trap 'umount "$top"; rmdir "$top"' EXIT
      cutoff=$(date -u -d "30 days ago" +%Y%m%dT%H%M%SZ)
      for old in "$top"/@old-roots/*; do
        [[ -e $old ]] || continue
        if [[ $(basename "$old") < $cutoff ]]; then
          btrfs subvolume delete --recursive "$old"
        fi
      done
    '';
  };

  environment.systemPackages = [ keepCopy ];

  # A switch that adds a kept path copies it here, before the new bind mount
  # covers the live path.
  system.activationScripts.oruc-keep-copy = {
    deps = [ "etc" ];
    text = ''
      if [[ -e /keep/.oruc-seeded ]]; then
        ${lib.getExe keepCopy} /keep /etc/oruc/kept-paths
      fi
    '';
  };

  # The kept paths, for the seed and dry-run scripts.
  environment.etc."oruc/kept-paths".text = lib.concatLines kept;
}
