# The Plasma style of the Glass look: Breeze with see-through popups. Breeze
# fills the background of menus, popups, notifications and KRunner with the
# window color at 85% opacity; this style fills it at 50%, the opacity of the
# top bar's widgets, so the Glass blur shows through. Plasma takes every
# element this style leaves out from Breeze.
{
  jq,
  libplasma,
  runCommandLocal,
}:
runCommandLocal "oruc-glass-plasma-theme" { nativeBuildInputs = [ jq ]; } ''
  breeze=${libplasma}/share/plasma/desktoptheme/default
  dir=$out/share/plasma/desktoptheme/oruc-glass
  mkdir -p "$dir/translucent"
  cp "$breeze/plasmarc" "$dir/"

  jq '.KPlugin |= (with_entries(select(.key | test("\\[") | not))
        | .Id = "oruc-glass" | .Name = "Oruc Glass"
        | .Description = "Breeze with see-through popups")' \
    "$breeze/metadata.json" >"$dir/metadata.json"

  # Plasma uses the translucent variant while a blur effect runs, and the
  # plain one otherwise.
  for svg in dialogs/background.svgz translucent/dialogs/background.svgz; do
    mkdir -p "$(dirname "$dir/$svg")"
    gunzip -c "$breeze/$svg" >background.svg
    if ! grep -q 'opacity:0\.85' background.svg; then
      echo "$svg has no fill at 85% opacity; Breeze changed its dialog background" >&2
      exit 1
    fi
    sed -i 's/opacity:0\.85/opacity:0.5/g' background.svg
    gzip -9n <background.svg >"$dir/$svg"
  done

  # Looking up a missing colors file on every popup slows popups down, as with
  # Breeze (theme.nix). Plasma never reads the file, so the colors still come
  # from kdeglobals.
  touch "$dir/translucent/colors"
''
