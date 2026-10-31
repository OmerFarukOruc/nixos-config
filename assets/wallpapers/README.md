# Wallpapers

A scheme without a wallpaper of its own gets `default.png` recolored to the
scheme's 16 colors. `oruc-wallpaper-path` (`home-manager/modules/wallpaper.nix`)
renders it the first time `theme` selects the scheme and keeps it in
`~/.cache/oruc/wallpapers`; NixOS recolors the record scheme's in
`nixosModules/theme-module.nix` (the `wallpaper` value). To
give a scheme its own wallpaper, add a file named after it, for example
`gruvbox-dark-medium.png`. PNG, JPEG, and WebP files are discovered without
adding host-specific monitor or layout policy. When several files carry the
scheme's name, the first extension in the order `.png`, `.jpg`, `.jpeg`, `.webp`
wins.

Noctalia writes a wallpaper picked in its panel to
`~/.local/state/noctalia/settings.toml`, which overrides the config this
repository generates. `theme`, `theme --reapply` and each start of
`noctalia.service` set the scheme's wallpaper through
`noctalia msg wallpaper-set`. A pick for all monitors writes `[wallpaper.default]` and
`[wallpaper.last]`. A pick for one monitor writes `[wallpaper.monitors.<connector>]`
and `[wallpaper.last]`. To return to the wallpaper from this directory, delete
the `[wallpaper.default]`, `[wallpaper.last]` and `[wallpaper.monitors.*]`
tables from that file and restart `noctalia.service`. The Noctalia source at
v5.2.1 (`src/config/config_overrides.cpp`) confirmed this; recheck it when
Noctalia moves.
