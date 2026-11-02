# Wallpapers

A scheme without a wallpaper of its own gets `default.png` recolored to the
scheme's 16 colors while preserving its luminosity (`lutgen apply -R -P`), so
`#000000` voids stay black on OLED panels. `oruc-wallpaper-path`
(`home-manager/modules/wallpaper.nix`) looks in `assets/wallpapers/<host>` first
and then `assets/wallpapers`, renders a missing scheme from the matching
`default.png` the first time `theme` selects it, and keeps the result in
`~/.cache/oruc/wallpapers`. To give a scheme its own wallpaper, add a file named
after it, such as `warm-burnout-dark.png` or `nixos-rog/warm-burnout-dark.png`.
PNG, JPEG, and WebP files are discovered; when several files carry the scheme's
name in the same folder, the first extension in the order `.png`, `.jpg`,
`.jpeg`, `.webp` wins.

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
