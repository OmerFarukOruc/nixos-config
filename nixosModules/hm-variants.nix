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
  hm = config.home-manager.users.${cfg.user};
  variants = import ../machines/variants.nix { inherit lib sessions; } cfg;
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

  common = ''
    state=${lib.escapeShellArg hm.oruc.themeState}
    pointer=${lib.getExe hm.oruc.themePointer}
    base=${hm.home.activationPackage}
    default_look=${
      lib.escapeShellArg (if variants.defaultLook == null then "" else variants.defaultLook)
    }
    default_scheme=${lib.escapeShellArg variants.defaultScheme}
    looks=(${lib.escapeShellArgs variants.looks})
    schemes=(${lib.escapeShellArgs variants.schemes})
    variant_rows=${
      lib.escapeShellArg (
        lib.concatMapStrings (
          row: "${if row.generation then "1" else "0"}|${row.name}|${row.scheme}|${row.look or ""}\n"
        ) variants.rows
      )
    }

    stored() {
      local file=$1 default=$2 known=$3 choice
      choice=$(cat "$state/$file" 2>/dev/null || true)
      if [[ -n $choice ]] && "$known" "$choice"; then
        echo "$choice"
      else
        [[ -z $choice ]] || echo "$file: the stored $choice no longer exists; $default stays" >&2
        echo "$default"
      fi
    }
    is_look() { [[ " ''${looks[*]} " == *" $1 "* ]]; }
    stored_look() { stored plasma-look "$default_look" is_look; }
    stored_scheme() { "$pointer" --stored; }
    in_pack() { "$pointer" --list 2>/dev/null | grep -xF -- "$1" >/dev/null; }

    hold_switch_lock() {
      mkdir -p "$state"
      exec 8>"$state/switch.lock"
      flock 8
    }
    row_scheme() {
      if [[ " ''${schemes[*]} " == *" $1 "* ]]; then
        echo "$1"
      else
        echo "$default_scheme"
      fi
    }

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

    # The session's display and bus, as Home Manager's own service imports
    # them, so the activation and the live steps reach KWin from SSH or a
    # system unit too.
    session_env() {
      if [[ -z ''${DBUS_SESSION_BUS_ADDRESS:-} || -z ''${WAYLAND_DISPLAY:-} ]]; then
        eval "$(
          XDG_RUNTIME_DIR=''${XDG_RUNTIME_DIR:-/run/user/$(id -u)} systemctl --user show-environment 2>/dev/null |
            sed -En '/^(DBUS_SESSION_BUS_ADDRESS|DISPLAY|WAYLAND_DISPLAY|XAUTHORITY|XDG_RUNTIME_DIR)=/s/^/export /p'
        )"
      fi
    }

    activate() {
      local dir
      dir=$(variant_dir "$1" "$2") || return 1
      if ! grep -qF " $base" /run/current-system/etc/systemd/system/home-manager-${cfg.user}.service; then
        echo "A deploy replaced the system after this command started; run it again." >&2
        return 1
      fi
      session_env
      "$dir/activate" --driver-version ${driverVersion} 8>&-
    }

    live() {
      ${lib.optionalString hasPlasma ''
        session_env
        if [[ -z ''${WAYLAND_DISPLAY:-} ]]; then
          echo "No desktop session runs, so the KDE colours change at the next login."
        elif ${lib.getExe hm.oruc.plasma.live} "$1" 8>&-; then
          return 0
        else
          echo "theme: the KDE colours, dark or light set, Plasma style or Glass glow failed" >&2
        fi
      ''}
      return 1
    }

    reload() {
      :
      ${lib.concatLines (
        lib.mapAttrsToList (name: command: ''
          if ! (
            ${command}
          ) 8>&-; then
            echo ${lib.escapeShellArg "theme: ${name} reload failed"} >&2
          fi
        '') hm.oruc.variantReloads
      )}
    }

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
        gnugrep
        gnused
        procps
        systemd
        util-linux
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
      Usage: theme [SCHEME | --list | --reapply]

      With no argument, prints the active Base16 scheme. --list prints every scheme
      of the installed theme pack, the store path that holds each scheme's colour files.
      SCHEME activates that scheme and keeps it across deploys. Ghostty, tmux, Neovim
      and a Claude Code that selects custom:scheme take its colours at once; Starship,
      fzf and atuin at their next run, and the Markdown viewer at its next open. On
      Plasma, KDE and GTK 4 apps, the cursor, the icons and the Glass glow change at
      once, and GTK 3 apps and Kate's editor at their next start. VS Code changes its
      colours at once and its see-through window at its next start. niri's
      focus ring, Noctalia and DMS change at once; rofi and vicinae at their
      next open, wlogout and mpv at their next start, and the Plasma splash at
      the next login.
      --reapply points the colour files at the stored scheme again and activates the
      stored Plasma look. The Home Manager service runs it after it activates the
      default ones.
      The login screen, the boot menu and the console keep the scheme of the
      machine record.'';
    text = ''
      case ''${1:-} in
        "") echo "active: $(stored_scheme) (default: $default_scheme)" ;;
        --list) "$pointer" --list ;;
        -h | --help) usage ;;
        --reapply)
          hold_switch_lock
          "$pointer"
          look=$(stored_look) row=$(row_scheme "$(stored_scheme)")
          [[ $look == "$default_look" && $row == "$default_scheme" ]] && exit 0
          activate "$look" "$row"
          reload
          ;;
        *)
          if ! in_pack "$1"; then
            usage >&2
            exit 64
          fi
          hold_switch_lock
          look=$(stored_look) row=$(row_scheme "$1")
          if [[ $row != "$(row_scheme "$(stored_scheme)")" ]]; then
            activate "$look" "$row" || exit 1
          fi
          "$pointer" --set "$1"
          reload
          shown="Ghostty, tmux, Neovim and VS Code"
          if live "$look"; then
            shown="Ghostty, tmux, Neovim, VS Code, KDE and GTK 4 apps"
          fi
          echo "$shown show $1 now; Starship, fzf and atuin at their next run."
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
          hold_switch_lock
          choose plasma-look "$1"
          activate "$1" "$(row_scheme "$(stored_scheme)")"
          reload
          echo "Log out and in to load the $1 look's colors, Plasma style, panels and KWin effects."
          ;;
      esac
    '';
  };
in
{
  config = lib.mkIf (cfg.kind == "workstation" && config.home-manager.users ? ${cfg.user}) {
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
    systemd.services."home-manager-${cfg.user}".serviceConfig.ExecStartPost = lib.getExe (
      pkgs.writeShellApplication {
        name = "theme-reapply";
        text = ''
          state=${lib.escapeShellArg hm.oruc.themeState}
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
