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
  themeValues = import ./theme-values.nix { inherit lib; };
  systemThemeValues = import ./system-theme-values.nix { inherit lib; };
  catalogue = lib.mapAttrs (_: config.lib.base16.mkSchemeAttrs) (
    import ../machines/schemes.nix { inherit inputs lib; }
  );
  recordLogin = systemThemeValues.sddmConfUser config.scheme;
  text = name: builtins.toFile (lib.strings.sanitizeDerivationName name);

  pack = pkgs.linkFarm "oruc-system-theme-pack" (
    lib.concatLists (
      lib.mapAttrsToList (slug: scheme: [
        {
          name = "${slug}/vtrgb";
          path = text "vtrgb" (systemThemeValues.vtrgb scheme);
        }
        {
          name = "${slug}/sddm.conf.user";
          path = text "sddm.conf.user" (
            if (themeValues scheme).isLight then recordLogin else systemThemeValues.sddmConfUser scheme
          );
        }
      ]) catalogue
    )
  );

  helper = pkgs.writeShellApplication {
    name = "oruc-theme-root";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.kbd
    ];
    text = ''
      pack=${pack}
      record=${lib.escapeShellArg cfg.theme.scheme}
      state=/var/lib/oruc/theme
      colors_file=${lib.escapeShellArg config.oruc.login.colorsFile}
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

      mkdir -p "$state" "''${colors_file%/*}"
      case ''${1:-} in
        "")
          slug=
          read -r slug || true
          if ! in_pack "$slug"; then
            echo "oruc-theme-root: $slug is not a scheme of the system pack" >&2
            exit 64
          fi
          write <(printf '%s\n' "$slug") "$state/scheme" || report "storing the scheme"
          ;;
        --apply)
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
  config = lib.mkIf themed {
    environment.systemPackages = [ helper ];

    security.sudo.extraRules = [
      {
        users = [ cfg.user ];
        commands = [
          {
            command = "/run/current-system/sw/bin/oruc-theme-root";
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];

    systemd.services.oruc-theme-root = {
      description = "Apply the stored scheme to the console and the login screen";
      wantedBy = [ "multi-user.target" ];
      before = [ "display-manager.service" ];
      after = [ "local-fs.target" ];
      serviceConfig.Type = "oneshot";
      script = "${lib.getExe helper} --apply || echo 'oruc-theme-root: --apply failed' >&2";
    };
  };
}
