# The Home Manager variants of oruc (machines/variants.nix): one per Plasma
# look and scheme. `plasma-look <look>` and `theme <scheme>` store a choice
# and activate the variant of both stored choices. Each deploy and each boot
# activates the default variant, so the Home Manager service then activates
# the stored one.
{
  config,
  lib,
  pkgs,
  sessions,
  ...
}:
let
  cfg = config.oruc.machine;
  hasPlasma = sessions.hasDesktop cfg "plasma";
  hm = config.home-manager.users.oruc;
  variants = import ../machines/variants.nix { inherit lib sessions; } cfg;
  # Home Manager's own service passes the same version.
  driverVersion = if config.home-manager.enableLegacyProfileManagement then "0" else "1";

  # NixOS installs only the generation's own packages (useUserPackages), so
  # a variant that builds another package would keep the generation's.
  packageDrvs = hmConfig: map (p: p.drvPath) hmConfig.home.packages;
  basePackages = packageDrvs hm;
  packageDrift = lib.filterAttrs (_: extra: extra != [ ]) (
    lib.mapAttrs (
      _: specialisation:
      map builtins.unsafeDiscardStringContext (
        lib.subtractLists basePackages (packageDrvs specialisation.configuration)
      )
    ) hm.specialisation
  );

  # The shell functions that both commands share.
  common = ''
    state=''${XDG_STATE_HOME:-$HOME/.local/state}/oruc
    base=${hm.home.activationPackage}
    default_look=${
      lib.escapeShellArg (if variants.defaultLook == null then "" else variants.defaultLook)
    }
    default_scheme=${lib.escapeShellArg variants.defaultScheme}
    looks=(${lib.escapeShellArgs variants.looks})
    schemes=(${lib.escapeShellArgs variants.schemes})
    # generation|name|scheme|look. look is empty when the machine has no Plasma.
    # machines/variants.nix is the only place that builds name.
    variant_rows=${
      lib.escapeShellArg (
        lib.concatMapStrings (
          row: "${if row.generation then "1" else "0"}|${row.name}|${row.scheme}|${row.look or ""}\n"
        ) variants.rows
      )
    }

    # stored FILE DEFAULT CHOICE...: the stored choice, or DEFAULT when none
    # is stored or the stored one no longer exists.
    stored() {
      local file=$1 default=$2 choice
      shift 2
      choice=$(cat "$state/$file" 2>/dev/null || true)
      if [[ -n $choice && " $* " == *" $choice "* ]]; then
        echo "$choice"
      else
        [[ -z $choice ]] || echo "$file: the stored $choice no longer exists; $default stays" >&2
        echo "$default"
      fi
    }
    stored_look() { stored plasma-look "$default_look" "''${looks[@]}"; }
    stored_scheme() { stored scheme "$default_scheme" "''${schemes[@]}"; }

    # variant_dir LOOK SCHEME prints the activation directory of that row.
    variant_dir() {
      local want_look=$1 want_scheme=$2 gen name scheme look
      while IFS='|' read -r gen name scheme look; do
        [[ -n $scheme ]] || continue
        if [[ $scheme == "$want_scheme" && $look == "$want_look" ]]; then
          if [[ $gen == 1 ]]; then
            printf '%s\n' "$base"
          else
            printf '%s\n' "$base/specialisation/$name"
          fi
          return 0
        fi
      done <<<"$variant_rows"
      echo "no variant for look '$want_look' and scheme '$want_scheme'" >&2
      return 1
    }

    # activate LOOK SCHEME: activates their variant.
    activate() {
      local dir
      dir=$(variant_dir "$1" "$2") || return 1
      # The session's display and bus, as Home Manager's own service imports
      # them, so the activation reaches KWin from SSH or a system unit too.
      if [[ -z ''${DBUS_SESSION_BUS_ADDRESS:-} ]]; then
        eval "$(
          XDG_RUNTIME_DIR=''${XDG_RUNTIME_DIR:-/run/user/$(id -u)} systemctl --user show-environment 2>/dev/null |
            sed -En '/^(DBUS_SESSION_BUS_ADDRESS|DISPLAY|WAYLAND_DISPLAY|XAUTHORITY|XDG_RUNTIME_DIR)=/s/^/export /p'
        )"
      fi
      "$dir/activate" --driver-version ${driverVersion}
      ${lib.concatStringsSep "\n" (map (command: "      ${command}") hm.oruc.variantReloads)}
    }

    # choose FILE CHOICE: stores the choice for the next activations.
    choose() {
      mkdir -p "$state"
      echo "$2" >"$state/$1"
    }
  '';

  mkCommand =
    {
      name,
      usage,
      text,
    }:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = with pkgs; [
        coreutils
        gnused
        procps
        systemd
      ];
      text = ''
        ${common}
        usage() {
          cat <<EOF
        ${usage}
        EOF
        }
        ${text}
      '';
    };

  theme = mkCommand {
    name = "theme";
    usage = ''
      Usage: theme [SCHEME | --reapply]

      With no argument, prints the active Base16 scheme and the schemes to choose from.
      SCHEME activates that scheme and keeps it across deploys. Ghostty, new Neovim
      windows and a Claude Code that selects custom:scheme take its colors at once,
      VS Code at its next start; log out and in to load its KDE colors.
      --reapply activates the stored scheme and Plasma look again. The Home Manager
      service runs it after it activates the default ones.
      The login screen, the boot menu, the console and niri keep the scheme of the
      machine record.'';
    text = ''
      case ''${1:-} in
        "")
          echo "active: $(stored_scheme)"
          echo "schemes: ''${schemes[*]} (default: $default_scheme)"
          ;;
        -h | --help) usage ;;
        --reapply)
          look=$(stored_look) scheme=$(stored_scheme)
          [[ $look == "$default_look" && $scheme == "$default_scheme" ]] && exit 0
          activate "$look" "$scheme"
          ;;
        *)
          if [[ " ''${schemes[*]} " != *" $1 "* ]]; then
            usage >&2
            exit 64
          fi
          choose scheme "$1"
          activate "$(stored_look)" "$1"
          echo "Ghostty and new Neovim windows take the $1 colors, VS Code at its next start. Log out and in to load its KDE colors."
          ;;
      esac
    '';
  };

  plasmaLook = mkCommand {
    name = "plasma-look";
    usage = ''
      Usage: plasma-look [LOOK]

      With no argument, prints the active Plasma look and the looks to choose from.
      LOOK activates that look and keeps it across deploys; log out and in to
      load its colors, Plasma style, panels and KWin effects.'';
    text = ''
      case ''${1:-} in
        "")
          echo "active: $(stored_look)"
          echo "looks: ''${looks[*]} (default: $default_look)"
          ;;
        -h | --help) usage ;;
        *)
          if [[ " ''${looks[*]} " != *" $1 "* ]]; then
            usage >&2
            exit 64
          fi
          choose plasma-look "$1"
          activate "$1" "$(stored_scheme)"
          echo "Log out and in to load the $1 look's colors, Plasma style, panels and KWin effects."
          ;;
      esac
    '';
  };
in
{
  config = lib.mkIf (config.home-manager.users ? oruc) {
    assertions = [
      {
        assertion = packageDrift == { };
        message =
          "A Home Manager specialisation builds packages that the generation does not, and "
          + "NixOS installs only the generation's (home-manager/modules/variants.nix). Pass the "
          + "color through a file instead. Extra packages: "
          + lib.concatStringsSep "; " (
            lib.mapAttrsToList (name: extra: "${name}: ${lib.concatStringsSep ", " extra}") packageDrift
          );
      }
    ];

    environment.systemPackages = [ theme ] ++ lib.optional hasPlasma plasmaLook;

    # A failed reapply must not fail this unit, because a failed unit makes
    # deploy.sh roll back the whole system. The wrapper records the failure
    # where scripts/verify-nixos-rog.sh can see it.
    systemd.services.home-manager-oruc.serviceConfig.ExecStartPost = lib.getExe (
      pkgs.writeShellApplication {
        name = "theme-reapply";
        text = ''
          state=''${XDG_STATE_HOME:-$HOME/.local/state}/oruc
          mkdir -p "$state"
          if ${lib.getExe theme} --reapply; then
            rm -f "$state/reapply-failed"
          else
            echo failed >"$state/reapply-failed"
          fi
        '';
      }
    );
  };
}
