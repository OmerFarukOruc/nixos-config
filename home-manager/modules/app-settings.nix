{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) types mkOption;
  cfg = config.oruc.appSettings;

  file = types.submodule {
    options = {
      path = mkOption {
        type = types.str;
        description = "Absolute path of the file; {vault} expands to each Obsidian vault of the app's vaults file, {profile} to the default profile of its profiles.ini.";
      };
      format = mkOption {
        type = types.enum [
          "json"
          "toml"
          "ini"
          "userjs"
          "copy"
        ];
        description = "json, toml and ini merge the values into the file, userjs sets user_pref lines, and copy writes the pack file named by source.";
      };
      values = mkOption {
        type = types.nullOr (types.either (types.attrsOf types.anything) (types.listOf types.anything));
        default = null;
        description = "Values to merge, the same for every scheme.";
      };
      fact = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Name of an oruc.themeFacts entry whose JSON holds the values for the stored scheme.";
      };
      source = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Key of an oruc.themeFiles entry that a copy writes.";
      };
      create = mkOption {
        type = types.bool;
        default = true;
        description = "Create the file when it is missing; false leaves a missing file to the app, for one that needs its own first start.";
      };
      live = mkOption {
        type = types.bool;
        default = false;
        description = "Write the file even while the app runs, for a file the app only reads.";
      };
    };
  };

  executable = types.submodule {
    options = {
      package = mkOption {
        type = types.str;
        description = "Regular expression for the package name between the store hash and the version.";
      };
      path = mkOption {
        type = types.str;
        description = "Regular expression for the executable's path inside the package.";
      };
    };
  };

  terminalSignal = types.submodule {
    options = {
      name = mkOption {
        type = types.str;
        description = "Name of the signal, such as SIGUSR2.";
      };
      subcommands = mkOption {
        type = types.listOf types.str;
        description = "First arguments that start a mode without the terminal UI.";
      };
      valueFlags = mkOption {
        type = types.listOf types.str;
        description = "Flags that take the next argument as their value.";
      };
    };
  };

  app = types.submodule {
    options = {
      label = mkOption {
        type = types.str;
        description = "The app's name in the line that says it runs.";
      };
      executables = mkOption {
        type = types.listOf executable;
        default = [ ];
        description = "Executables whose /proc/<pid>/exe shows a running app, from any store path of the package.";
      };
      commandLines = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Regular expressions searched in the command line of a running app, for one started by an interpreter.";
      };
      servers = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "First arguments of a background server of the app that writes its settings only for a client; it and its children do not count as the app running.";
      };
      terminalSignal = mkOption {
        type = types.nullOr terminalSignal;
        default = null;
        description = "The signal sent to each running process of the app whose first argument that is not a flag or a flag's value is no subcommand.";
      };
      vaults = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Obsidian's vault list, which {vault} reads.";
      };
      profiles = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "A Mozilla profiles.ini, which {profile} reads.";
      };
      files = mkOption {
        type = types.listOf file;
        description = "Files the switch sets; one the app also writes waits while the app runs.";
      };
    };
  };

  spec = pkgs.writeText "oruc-app-settings.json" (
    builtins.toJSON {
      current = builtins.dirOf config.oruc.themeFactsDir;
      apps = lib.mapAttrs (
        _: app:
        app
        // {
          executables = map (exe: "/nix/store/[a-z0-9]{32}-${exe.package}-[^/]+/${exe.path}") app.executables;
        }
      ) cfg;
    }
  );
  script = pkgs.writers.writePython3 "oruc-app-settings-script" {
    libraries = [ (pkgs.callPackage ./settings-file.nix { }) ];
  } (builtins.readFile ./app-settings.py);
  tool = pkgs.writeShellScriptBin "oruc-app-settings" ''exec ${script} ${spec} "$@"'';
in
{
  options.oruc.appSettings = mkOption {
    type = types.attrsOf app;
    default = { };
    description = "App settings files that each theme switch points at the stored scheme, through oruc-app-settings.";
  };

  config = lib.mkIf (cfg != { }) {
    home.packages = [ tool ];
    oruc.variantReloads = lib.mapAttrs (name: _: "${lib.getExe tool} ${lib.escapeShellArg name}") cfg;
    assertions = lib.concatLists (
      lib.mapAttrsToList (
        name: app:
        lib.concatMap (entry: [
          {
            assertion = !lib.hasInfix "{vault}" entry.path || app.vaults != null;
            message = "oruc.appSettings.${name}: ${entry.path} names {vault}, so the app needs vaults.";
          }
          {
            assertion = !lib.hasInfix "{profile}" entry.path || app.profiles != null;
            message = "oruc.appSettings.${name}: ${entry.path} names {profile}, so the app needs profiles.";
          }
          {
            assertion =
              if entry.format == "copy" then
                entry.source != null
              else
                lib.length (
                  lib.filter (x: x != null) [
                    entry.values
                    entry.fact
                  ]
                ) == 1;
            message = "oruc.appSettings.${name}: ${entry.path} needs a source for copy, else exactly one of values and fact.";
          }
        ]) app.files
      ) cfg
    );
  };
}
