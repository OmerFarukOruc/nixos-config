{ lib }:
rec {
  channels =
    color:
    map (i: lib.fromHexString (builtins.substring (2 * i) 2 color)) [
      0
      1
      2
    ];

  linear =
    let
      fifthRoot =
        x: builtins.foldl' (y: _: y - (y * y * y * y * y - x) / (5.0 * y * y * y * y)) 1.0 (lib.range 1 40);
    in
    lib.genList (
      value:
      let
        v = value / 255.0;
      in
      if v <= 0.03928 then
        v / 12.92
      else
        let
          u = (v + 0.055) / 1.055;
          r = fifthRoot u;
        in
        u * u * r * r
    ) 256;

  luminance =
    rgb:
    let
      part = i: builtins.elemAt linear (builtins.elemAt rgb i);
    in
    0.2126 * part 0 + 0.7152 * part 1 + 0.0722 * part 2;

  contrast = la: lb: (lib.max la lb + 0.05) / (lib.min la lb + 0.05);

  readableOn =
    scheme: background:
    let
      on = color: contrast (luminance (channels color)) (luminance (channels background));
      higher = a: b: if on a >= on b then a else b;
      fromScheme = higher scheme.base00 scheme.base07;
    in
    lib.toLower (if on fromScheme >= 4.5 then fromScheme else higher "000000" "ffffff");

  mix = pct: lib.zipListsWith (a: b: (a * pct + b * (100 - pct) + 50) / 100);
  mixHex =
    pct: a: b:
    lib.concatMapStrings (value: lib.optionalString (value < 16) "0" + lib.toHexString value) (
      mix pct (channels a) (channels b)
    );

  legibleOn =
    scheme: backgrounds: color:
    let
      from = channels color;
      worst =
        surfaces: rgb:
        let
          on = contrast (luminance rgb);
        in
        lib.foldl' (low: surface: lib.min low (on surface)) (on (builtins.head surfaces)) (
          builtins.tail surfaces
        );
      toward =
        surfaces: target:
        let
          to = channels target;
          pct = lib.findFirst (pct: worst surfaces (mix (100 - pct) from to) >= 4.5) null (lib.range 0 100);
        in
        if pct == null then null else mixHex (100 - pct) color target;
      lift =
        surfaces:
        let
          extreme =
            if worst surfaces (channels "000000") > worst surfaces (channels "ffffff") then
              "000000"
            else
              "ffffff";
          fromScheme = toward surfaces scheme.base05;
        in
        if fromScheme != null then fromScheme else toward surfaces extreme;
      surfaces = map (background: luminance (channels background)) backgrounds;
      onAll = lift surfaces;
    in
    if onAll != null then onAll else lift [ (builtins.head surfaces) ];

  textRoles =
    scheme: backgrounds:
    let
      lift = legibleOn scheme backgrounds;
      on =
        color: contrast (luminance (channels color)) (luminance (channels (builtins.head backgrounds)));
      foreground = lift scheme.base05;
      floor = lift scheme.base00;
      capped =
        color:
        if on color < on foreground then
          color
        else if on floor < on foreground then
          floor
        else
          foreground;
      faint = capped (lift scheme.base03);
      lifted = capped (lift scheme.base04);
      between = capped (lift (mixHex 50 faint foreground));
      dim =
        if faint != foreground && on lifted > on faint then
          lifted
        else if on between <= on faint then
          foreground
        else
          between;
    in
    lib.mapAttrs (_: lib.toLower) { inherit foreground dim faint; };

  hoverOf =
    background: text:
    lib.toLower (
      mixHex 85 background (
        if luminance (channels text) < luminance (channels background) then "ffffff" else "000000"
      )
    );
}
