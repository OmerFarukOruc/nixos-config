{
  inputs,
  osConfig,
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
  inherit (osConfig) scheme;
in
{
  imports = [ inputs.spicetify-nix.homeManagerModules.spicetify ];

  programs.spicetify = {
    enable = true;
    spotifyPackage = pinned.spotify;
    spicetifyPackage = pinned.spicetify-cli;
    # Spotify's stock layout, recoloured with the key mapping of Stylix's
    # spicetify target, except player: Marketplace paints its cards with it,
    # and Stylix's light base04 left their base05 text unreadable.
    theme = {
      # Marketplace installs a theme only while the local theme is named
      # marketplace. Its themes override these colours, and removing one
      # brings them back.
      name = "marketplace";
      src = pkgs.writeTextFile {
        name = "color.ini";
        destination = "/color.ini";
        text = with scheme; ''
          [base]
          text               = ${base05}
          subtext            = ${base05}
          main               = ${base00}
          main-elevated      = ${base02}
          highlight          = ${base02}
          highlight-elevated = ${base03}
          sidebar            = ${base01}
          player             = ${base01}
          card               = ${base03}
          shadow             = ${base00}
          selected-row       = ${base04}
          button             = ${base04}
          button-active      = ${base04}
          button-disabled    = ${base03}
          tab-active         = ${base02}
          notification       = ${base02}
          notification-error = ${base08}
          equalizer          = ${base0B}
          misc               = ${base02}
        '';
      };
      # The sidebar config breaks Spotify's current navigation bar.
      sidebarConfig = false;
    };
    colorScheme = "base";
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
