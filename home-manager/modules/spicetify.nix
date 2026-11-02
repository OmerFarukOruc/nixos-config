{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  inherit (pkgs.stdenv.hostPlatform) system;
  pinned = import inputs.nixpkgs-spotify {
    inherit system;
    config.allowUnfree = true;
  };
  spicePkgs = inputs.spicetify-nix.legacyPackages.${system};
  spicetify = config.programs.spicetify;
  roles = scheme: {
    text = scheme.base05;
    subtext = scheme.base04;
    nav-active-text = scheme.base0D;
    main = scheme.base00;
    main-elevated = scheme.base01;
    highlight = scheme.base01;
    highlight-elevated = scheme.base02;
    sidebar = scheme.base00;
    player = scheme.base00;
    card = scheme.base01;
    shadow = scheme.base00;
    selected-row = scheme.base05;
    main-secondary = scheme.base01;
    button = scheme.base0D;
    button-secondary = scheme.base03;
    button-active = scheme.base0D;
    button-disabled = scheme.base02;
    nav-active = scheme.base01;
    play-button = scheme.base0D;
    tab-active = scheme.base01;
    notification = scheme.base02;
    notification-error = scheme.base08;
    playback-bar = scheme.base03;
    misc = scheme.base05;
  };
  colors =
    { scheme, ... }:
    let
      css = lib.concatStrings (
        lib.mapAttrsToList (name: color: ''
          --spice-${name}: #${color};
          --spice-rgb-${name}: ${contrast.decimal color};
        '') (roles scheme)
      );
    in
    ":root {\n${css}}\n";
  contrast = import ../../nixosModules/contrast.nix { inherit lib; };
  spotify = spicetify.spicedSpotify.overrideAttrs (old: {
    postInstall = old.postInstall + ''
      ln -sfT ${lib.escapeShellArg "${config.oruc.themeFactsDir}/spicetify-colors.css"} "$out/share/spotify/Apps/xpui/colors.css"
    '';
  });
in
{
  imports = [ inputs.spicetify-nix.homeManagerModules.spicetify ];

  oruc.themeFacts."spicetify-colors.css" = colors;
  home.packages = [ spotify ] ++ spicetify.theme.extraPkgs;

  programs.spicetify = {
    enable = false;
    spotifyPackage = pinned.spotify;
    spicetifyPackage = pinned.spicetify-cli;
    # Marketplace refuses to install themes while this theme is set, because
    # the local theme is not named marketplace.
    theme = spicePkgs.themes.sleek // {
      additionalCss = ''
        .x-progressBar-fillColor,
        .progress-bar__slider {
          transition: none !important;
        }
      '';
    };
    enabledSnippets = with spicePkgs.snippets; [
      # keep-sorted start
      roundedNowPlaying
      # keep-sorted end
    ];
    enabledExtensions = with spicePkgs.extensions; [
      # keep-sorted start
      fullAppDisplay
      history
      keyboardShortcut
      simpleBeautifulLyrics
      songStats
      # keep-sorted end
    ];
    enabledCustomApps = with spicePkgs.apps; [
      # keep-sorted start
      lyricsPlus
      marketplace
      newReleases
      # keep-sorted end
    ];
  };
}
