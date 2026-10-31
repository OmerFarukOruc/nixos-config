{
  config,
  inputs,
  lib,
  pkgs,
  sessions,
  ...
}:
let
  cfg = config.oruc.machine;
  themed = sessions.hasAnyDesktop cfg;
  stateDir = "/var/lib/oruc/theme";
  colorsFile = "${stateDir}/sddm/jake_the_dog.conf.user";
  command = "/run/current-system/sw/bin/oruc-theme-root";
  systemThemeValues = import ./system-theme-values.nix { inherit lib; };
  shared = import ./scheme-catalogue.nix {
    inherit inputs lib;
    inherit (config.lib.base16) mkSchemeAttrs;
  };
  recordLogin = systemThemeValues.sddmConfUser config.scheme;

  pack = pkgs.linkFarm "oruc-system-theme-pack" (
    lib.concatLists (
      lib.mapAttrsToList (slug: entry: [
        {
          name = "${slug}/vtrgb";
          path = shared.toFile "vtrgb" (systemThemeValues.vtrgb entry.scheme);
        }
        {
          name = "${slug}/sddm.conf.user";
          path = shared.toFile "sddm.conf.user" (
            if entry.theme.isLight then recordLogin else systemThemeValues.sddmConfUser entry.scheme
          );
        }
      ]) shared.catalogue
    )
  );

  helper = pkgs.writeShellApplication {
    name = "oruc-theme-root";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.kbd
      pkgs.util-linux
    ];
    text = ''
      pack=${pack}
      record=${lib.escapeShellArg cfg.theme.scheme}
      state=${stateDir}
      colors_file=${colorsFile}
      failed=0

      usage() {
        cat >&2 <<'EOF'
      Usage: oruc-theme-root [--apply]

      With no argument, reads a scheme name from stdin, stores it, and applies it
      to the console and the login screen. --apply applies the stored scheme, or
      the machine record's scheme when none is stored.
      EOF
        exit 64
      }

      in_pack() { [[ $1 =~ ^[a-z0-9-]+$ && -d $pack/$1 ]]; }

      write() {
        local tmp
        mkdir -p "''${2%/*}" || return 1
        tmp=$(mktemp "$2.XXXXXX") || return 1
        if cat "$1" >"$tmp" && chmod 0644 "$tmp" && mv -T "$tmp" "$2"; then
          return 0
        fi
        rm -f "$tmp"
        return 1
      }

      report() {
        echo "oruc-theme-root: $1 failed for $slug" >&2
        failed=1
      }

      hold_lock() {
        mkdir -p "$state"
        exec 9>"$state/lock"
        if ! flock -w 60 9; then
          echo "oruc-theme-root: another run held $state/lock for 60 s" >&2
          exit 1
        fi
      }

      case ''${1:-} in
        "")
          slug=
          read -r slug || true
          if ! in_pack "$slug"; then
            echo "oruc-theme-root: $slug is not a scheme of the system pack" >&2
            exit 64
          fi
          hold_lock
          write <(printf '%s\n' "$slug") "$state/scheme" || report "storing the scheme"
          ;;
        --apply)
          hold_lock
          slug=$(cat "$state/scheme" 2>/dev/null || true)
          in_pack "$slug" || slug=$record
          ;;
        *) usage ;;
      esac
      setvtrgb "$pack/$slug/vtrgb" || report "the console"
      write "$pack/$slug/sddm.conf.user" "$colors_file" || report "the login screen"
      exit "$failed"
    '';
  };
in
{
  options.oruc.themeRoot = {
    colorsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      readOnly = true;
      description = "File that the login screen reads its colours from, written by oruc-theme-root, or null on a host without a desktop.";
    };
    command = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      readOnly = true;
      description = "Path of oruc-theme-root, which theme runs through sudo with the scheme on stdin, or null on a host without a desktop.";
    };
  };

  config = lib.mkMerge [
    {
      oruc.themeRoot = {
        colorsFile = if themed then colorsFile else null;
        command = if themed then command else null;
      };
    }

    (lib.mkIf themed {
      environment.systemPackages = [ helper ];

      security.sudo.extraRules = [
        {
          users = [ cfg.user ];
          commands = [
            {
              inherit command;
              options = [ "NOPASSWD" ];
            }
          ];
        }
      ];

      systemd.services.oruc-theme-root = {
        description = "Apply the stored scheme to the console and the login screen";
        wantedBy = [ "multi-user.target" ];
        before = [ "display-manager.service" ];
        serviceConfig.Type = "oneshot";
        script = ''
          if ${lib.getExe helper} --apply; then
            rm -f ${stateDir}/apply-failed || true
          else
            echo 'oruc-theme-root: --apply failed' >&2
            echo failed >${stateDir}/apply-failed || true
          fi
        '';
      };
    })
  ];
}
