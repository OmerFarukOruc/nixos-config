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
  limine = cfg.bootloader == "limine" && !config.boot.loader.limine.enrollConfig;
  limineColors =
    scheme:
    let
      style = systemThemeValues.limineStyle scheme;
    in
    lib.concatLines [
      "backdrop: ${style.backdrop}"
      "interface_branding_colour: ${style.interface.brandingColor}"
      "interface_help_colour: ${style.interface.helpColor}"
      "interface_help_colour_bright: ${style.interface.helpColorBright}"
      "term_palette: ${style.graphicalTerminal.palette}"
      "term_palette_bright: ${style.graphicalTerminal.brightPalette}"
      "term_foreground: ${style.graphicalTerminal.foreground}"
      "term_background: ${style.graphicalTerminal.background}"
      "term_foreground_bright: ${style.graphicalTerminal.brightForeground}"
      "term_background_bright: ${style.graphicalTerminal.brightBackground}"
    ];

  pack = pkgs.linkFarm "oruc-system-theme-pack" (
    lib.concatLists (
      lib.mapAttrsToList (
        slug: entry:
        [
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
        ]
        ++ lib.optional limine {
          name = "${slug}/limine";
          path = shared.toFile "limine" (limineColors entry.scheme);
        }
      ) shared.catalogue
    )
  );

  helper = pkgs.writeShellApplication {
    name = "oruc-theme-root";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.diffutils
      pkgs.gnugrep
      pkgs.gnused
      pkgs.kbd
      pkgs.util-linux
    ];
    text = ''
      pack=${pack}
      record=${lib.escapeShellArg cfg.theme.scheme}
      state=${stateDir}
      colors_file=${colorsFile}
      limine=${if limine then "1" else ""}
      limine_conf=''${ORUC_LIMINE_CONF:-/boot/limine/limine.conf}
      failed=0

      usage() {
        cat >&2 <<'EOF'
      Usage: oruc-theme-root [--apply | --limine]

      With no argument, reads a scheme name from stdin, stores it, and applies it
      to the console and the login screen. --apply applies the stored scheme to
      the console and the login screen, and --limine to the Limine boot menu, or
      the machine record's scheme when none is stored.
      EOF
        exit 64
      }

      in_pack() { [[ $1 =~ ^[a-z0-9-]+$ && -d $pack/$1 ]]; }

      replace() {
        if sync "$1" && mv -T "$1" "$2" && sync -f "$2"; then
          return 0
        fi
        rm -f "$1"
        return 1
      }

      write() {
        local tmp
        mkdir -p "''${2%/*}" || return 1
        tmp=$(mktemp "$2.XXXXXX") || return 1
        if ! cat "$1" >"$tmp" || ! chmod 0644 "$tmp"; then
          rm -f "$tmp"
          return 1
        fi
        replace "$tmp" "$2"
      }

      report() {
        echo "oruc-theme-root: $1 failed for $slug" >&2
        failed=1
      }

      unchanged() {
        echo "oruc-theme-root: limine.conf left unchanged: $1" >&2
      }

      boot_menu() {
        local colors=$pack/$slug/limine tmp line key count pattern
        local edits=()
        if [[ ! -f $limine_conf ]]; then
          unchanged "$limine_conf does not exist"
          return 1
        fi
        while IFS= read -r line; do
          key=''${line%%: *}
          count=$(grep -c "^$key:" "$limine_conf" || true)
          if [[ $count != 1 ]] || ! grep -q "^$key: " "$limine_conf"; then
            unchanged "$key appears $count times or without a space after its colon"
            return 1
          fi
          edits+=(-e "s/^$key: .*/$line/")
        done <"$colors"
        pattern="^($(cut -d: -f1 "$colors" | paste -sd '|')):"
        tmp=$(mktemp "$limine_conf.XXXXXX") || return 1
        chmod --reference="$limine_conf" "$tmp" 2>/dev/null || true
        if ! sed "''${edits[@]}" "$limine_conf" >"$tmp"; then
          rm -f "$tmp"
          unchanged "sed failed"
          return 1
        fi
        if ! cmp -s <(grep -vE "$pattern" "$limine_conf") <(grep -vE "$pattern" "$tmp") ||
          [[ $(grep -c "" "$limine_conf") != $(grep -c "" "$tmp") ]]; then
          rm -f "$tmp"
          unchanged "a line outside the colour keys would change"
          return 1
        fi
        replace "$tmp" "$limine_conf"
      }

      hold_lock() {
        mkdir -p "$state"
        exec 9>"$state/lock"
        if ! flock -w 60 9; then
          echo "oruc-theme-root: another run held $state/lock for 60 s" >&2
          exit 1
        fi
      }

      hold_switch_lock() {
        mkdir -p /run/nixos
        exec 8>/run/nixos/switch-to-configuration.lock
        if ! flock -w 60 8; then
          echo "oruc-theme-root: a system switch held its lock for 60 s" >&2
          exit 1
        fi
      }

      stored_or_record() {
        slug=$(cat "$state/scheme" 2>/dev/null || true)
        in_pack "$slug" || slug=$record
      }

      apply_session() {
        setvtrgb "$pack/$slug/vtrgb" || report "the console"
        write "$pack/$slug/sddm.conf.user" "$colors_file" || report "the login screen"
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
          apply_session
          ;;
        --apply)
          hold_lock
          stored_or_record
          apply_session
          ;;
        --limine)
          [[ -n $limine ]] || usage
          [[ -n ''${NIXOS_ACTION:-} ]] || hold_switch_lock
          hold_lock
          stored_or_record
          boot_menu || report "the boot menu"
          ;;
        *) usage ;;
      esac
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
    stateDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      readOnly = true;
      description = "Folder where oruc-theme-root stores the scheme in `scheme` and its unit marks a failed --apply in `apply-failed`, or null on a host without a desktop.";
    };
    pack = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      readOnly = true;
      description = "Store path with each scheme's console palette, login screen colours and Limine colours under <slug>/, which oruc-theme-root reads, or null on a host without a desktop.";
    };
    bootMenu = lib.mkOption {
      type = lib.types.bool;
      readOnly = true;
      description = "Whether oruc-theme-root --limine recolours the Limine boot menu: on a Limine host with a desktop whose limine.conf is not enrolled into the bootloader.";
    };
  };

  config = lib.mkMerge [
    {
      oruc.themeRoot = {
        colorsFile = if themed then colorsFile else null;
        command = if themed then command else null;
        stateDir = if themed then stateDir else null;
        pack = if themed then pack else null;
        bootMenu = themed && limine;
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

      boot.loader.limine.extraInstallCommands = lib.mkIf limine "${lib.getExe helper} --limine || echo 'oruc-theme-root: --limine failed; the boot menu keeps the record colours' >&2";

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
