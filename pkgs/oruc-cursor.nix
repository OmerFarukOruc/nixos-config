{
  bibata-cursors,
  coreutils,
  findutils,
  gnused,
  python3Packages,
  resvg,
  writeShellApplication,
}:
writeShellApplication {
  name = "oruc-cursor-build";
  runtimeInputs = [
    coreutils
    findutils
    gnused
    python3Packages.clickgen
    resvg
  ];
  text = ''
    if (($# != 5)); then
      echo "usage: oruc-cursor-build OUT NAME FILL OUTLINE ACCENT (colours as 6 hex digits)" >&2
      exit 64
    fi
    out=$1 name=$2 fill=$3 outline=$4 accent=$5
    src=${bibata-cursors.src}
    work=$(mktemp -d)
    trap 'rm -rf -- "$work"' EXIT

    mkdir "$work/frames" "$work/themes"
    find -L "$src/svg/modern" -name '*.svg' -exec cp -t "$work/frames" {} +
    chmod u+w "$work"/frames/*.svg
    sed -i -e "s/#00FF00/#$fill/g" -e "s/#0000FF/#$outline/g" -e "s/#FF0000/#$accent/g" "$work"/frames/*.svg
    for svg in "$work"/frames/*.svg; do
      resvg -w 256 -h 256 "$svg" "''${svg%.svg}.png"
    done
    ctgen "$src/configs/normal/x.build.toml" -p x11 -d "$work/frames" -o "$work/themes" -n "$name" >/dev/null
    mv -T "$work/themes/$name" "$out"
  '';
}
