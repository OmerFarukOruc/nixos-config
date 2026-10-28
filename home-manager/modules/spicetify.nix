{
  inputs,
  osConfig,
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
  inherit (osConfig) scheme;
in
{
  imports = [ inputs.spicetify-nix.homeManagerModules.spicetify ];

  programs.spicetify = {
    enable = true;
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
    customColorScheme = {
      text = scheme.base05;
      subtext = scheme.base04;
      nav-active-text = scheme.base0D;
      main = scheme.base00;
      sidebar = scheme.base00;
      player = scheme.base00;
      card = scheme.base01;
      shadow = scheme.base00;
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
