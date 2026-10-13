# Wallpapers

Add a wallpaper named after the selected Base16 scheme, for example
`gruvbox-dark-medium.png`. PNG, JPEG, and WebP files are discovered without
adding host-specific monitor or layout policy. When several files carry the
scheme's name, the first extension in the order `.png`, `.jpg`, `.jpeg`, `.webp`
wins (`nixosModules/theme.nix`, the `wallpaper` value).

Noctalia writes a wallpaper picked in its panel to
`~/.local/state/noctalia/settings.toml`, which overrides the config this
repository generates. A pick for all monitors writes `[wallpaper.default]` and
`[wallpaper.last]`. A pick for one monitor writes `[wallpaper.monitors.<connector>]`
and `[wallpaper.last]`. To return to the wallpaper from this directory, delete
the `[wallpaper.default]`, `[wallpaper.last]` and `[wallpaper.monitors.*]`
tables from that file and restart `noctalia.service`. The Noctalia source at
v5.2.1 (`src/config/config_overrides.cpp`) confirmed this; recheck it when
Noctalia moves.
