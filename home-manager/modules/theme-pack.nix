{
  config,
  inputs,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  machine = osConfig.oruc.machine;
  switchable = machine.kind == "workstation" && config.home.username == machine.user;
  inScope = lib.filterAttrs (slug: _: switchable || slug == machine.theme.scheme);
  sources = import ../../machines/schemes.nix {
    inherit inputs lib;
    parse = lib.id;
  };
  catalogue = lib.mapAttrs (
    _: parsed:
    let
      scheme = config.lib.base16.mkSchemeAttrs parsed;
    in
    {
      inherit scheme;
      theme = import ../../nixosModules/theme-values.nix { inherit lib; } scheme;
    }
  ) (inScope (import ../../machines/schemes.nix { inherit inputs lib; }));

  state = "${config.xdg.stateHome}/oruc";
  text = name: builtins.toFile (lib.strings.sanitizeDerivationName name);
  pack = pkgs.linkFarm "oruc-theme-pack" (
    [
      {
        name = "slugs";
        path = text "slugs" (lib.concatLines (lib.attrNames catalogue));
      }
    ]
    ++ lib.concatLists (
      lib.mapAttrsToList (
        slug: args:
        [
          {
            name = "${slug}/.oruc/polarity";
            path = text "polarity" "${args.theme.polarity}\n";
          }
          {
            name = "${slug}/.oruc/source.yaml";
            path = sources.${slug};
          }
        ]
        ++ lib.mapAttrsToList (name: render: {
          name = "${slug}/.oruc/${name}";
          path = text name (render args);
        }) config.oruc.themeFacts
        ++ lib.mapAttrsToList (key: render: {
          name = "${slug}/${key}";
          path = text key (render args);
        }) config.oruc.themeFiles
      ) catalogue
    )
  );

  pointer = pkgs.writeShellApplication {
    name = "oruc-theme-pointer";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.util-linux
      osConfig.nix.package
    ];
    text = ''
      state=${lib.escapeShellArg state}
      record=${lib.escapeShellArg machine.theme.scheme}
      slugs=$state/theme/pack/slugs
      home=${lib.escapeShellArg config.home.homeDirectory}
      copies=(${lib.escapeShellArgs config.oruc.themeCopies})

      stored() {
        local want
        want=$(cat "$state/scheme" 2>/dev/null || true)
        if [[ -n $want ]] && grep -qxF -- "$want" "$slugs" 2>/dev/null; then
          echo "$want"
        else
          [[ -z $want ]] || echo "theme: the stored $want is not in the installed pack; $record stays" >&2
          echo "$record"
        fi
      }

      case ''${1:-} in
        --list)
          cat "$slugs"
          exit
          ;;
        --stored)
          stored
          exit
          ;;
      esac

      mkdir -p "$state/theme"
      exec 9>"$state/theme/lock"
      flock 9
      case ''${1:-} in
        "") ;;
        --pack)
          nix-store --realise "$2" --add-root "$state/theme/pack" >/dev/null
          ;;
        --set)
          if ! grep -qxF -- "$2" "$slugs"; then
            echo "theme: $2 is not in the installed pack" >&2
            exit 1
          fi
          printf '%s\n' "$2" >"$state/scheme.tmp"
          mv -T "$state/scheme.tmp" "$state/scheme"
          ;;
        *)
          echo "Usage: oruc-theme-pointer [--pack PATH | --set SCHEME | --list | --stored]" >&2
          exit 64
          ;;
      esac
      ln -sfnT "pack/$(stored)" "$state/theme/current.tmp"
      mv -T "$state/theme/current.tmp" "$state/theme/current"
      for key in "''${copies[@]}"; do
        mkdir -p "$(dirname "$home/$key")"
        install -m 644 "$state/theme/current/$key" "$home/$key.oruc-tmp"
        mv -T "$home/$key.oruc-tmp" "$home/$key"
      done
    '';
  };
in
{
  options.oruc = {
    themeFiles = lib.mkOption {
      type = lib.types.attrsOf (lib.types.functionTo lib.types.str);
      default = { };
      description = "Colour files per scheme, keyed by path under $HOME; each function takes { scheme, theme } (base16.nix attrs and theme-values.nix values) and returns the file text.";
    };
    themeFacts = lib.mkOption {
      type = lib.types.attrsOf (lib.types.functionTo lib.types.str);
      default = { };
      description = "Values per scheme that only scripts read, written to <slug>/.oruc/<name> in the pack and reached through theme/current/.oruc/<name>; each function takes { scheme, theme }.";
    };
    themeCopies = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Keys of oruc.themeFiles that oruc-theme-pointer writes as regular files and replaces through a rename at each switch, for an app that does not notice a link whose target changed.";
    };
    themePack = lib.mkOption {
      type = lib.types.package;
      description = "Store path with every scheme's colour files under <slug>/<key>, the slugs file, and <slug>/.oruc/polarity and source.yaml.";
    };
    themePointer = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      description = "Command that, under a lock, roots a pack (--pack PATH) or stores a scheme (--set SCHEME), then points theme/current at the stored scheme in the pack, or at the record scheme. --list prints the pack's schemes and --stored the scheme that theme/current follows.";
    };
    themeState = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      description = "Folder that holds the stored scheme, the stored Plasma look and the theme links.";
    };
  };

  config = {
    oruc.themePack = pack;
    oruc.themePointer = pointer;
    oruc.themeState = state;

    home.file = lib.mapAttrs (key: _: {
      source = config.lib.file.mkOutOfStoreSymlink "${state}/theme/current/${key}";
    }) (removeAttrs config.oruc.themeFiles config.oruc.themeCopies);

    home.activation.orucThemePointer = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      run ${lib.getExe pointer} --pack ${config.oruc.themePack}
    '';
  };
}
