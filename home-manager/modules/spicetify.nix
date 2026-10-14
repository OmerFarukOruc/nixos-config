{
  inputs,
  pkgs,
  ...
}:
let
  inherit (pkgs.stdenv.hostPlatform) system;
  # legacyPackages refuses the unfree spotify, so import the pinned nixpkgs.
  pinned = import inputs.nixpkgs-spotify {
    inherit system;
    config.allowUnfree = true;
  };
  spicePkgs = inputs.spicetify-nix.legacyPackages.${system};
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
      # Continuous progress transitions keep the GPU busy during playback.
      additionalCss = ''
        .x-progressBar-fillColor,
        .progress-bar__slider {
          transition: none !important;
        }
      '';
    };
    colorScheme = "RosePine";
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
