{ lib }:
let
  digits = lib.stringToCharacters "0123456789abcdefABCDEF";
  digitPairs = lib.concatMap (high: map (low: high + low) digits) digits;
  hexValues = lib.genAttrs (digits ++ digitPairs) lib.fromHexString;
  hexBytes = lib.genList (value: lib.optionalString (value < 16) "0" + lib.toHexString value) 256;
in
rec {
  channels =
    color:
    map (i: hexValues.${builtins.substring (2 * i) 2 color}) [
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

  ratio = a: b: contrast (luminance (channels a)) (luminance (channels b));

  mostReadable =
    background: candidates:
    lib.foldl' (
      best: color: if ratio color background > ratio best background then color else best
    ) (builtins.head candidates) (builtins.tail candidates);

  cbrt =
    x:
    if x == 0 then
      0.0
    else
      builtins.foldl' (y: _: y - (y * y * y - x) / (3.0 * y * y)) 1.0 (lib.range 1 40);

  oklab =
    color:
    let
      rgb = map (builtins.elemAt linear) (channels color);
      r = builtins.elemAt rgb 0;
      g = builtins.elemAt rgb 1;
      b = builtins.elemAt rgb 2;
      l = cbrt (0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
      m = cbrt (0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
      s = cbrt (0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
    in
    [
      (0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s)
      (1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s)
      (0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s)
    ];

  oklabDistanceSquaredWeighted =
    weights: a: b:
    lib.foldl' builtins.add 0.0 (
      lib.zipListsWith (weight: d: weight * d * d) weights (
        lib.zipListsWith builtins.sub (oklab a) (oklab b)
      )
    );

  oklabDistanceSquared = oklabDistanceSquaredWeighted [
    1
    1
    1
  ];

  minBy =
    score: candidates:
    lib.foldl' (best: next: if score next < score best then next else best) (builtins.head candidates) (
      builtins.tail candidates
    );

  readableOn =
    scheme: background:
    let
      fromScheme = mostReadable background [
        scheme.base00
        scheme.base07
      ];
    in
    lib.toLower (
      if ratio fromScheme background >= 4.5 then
        fromScheme
      else
        mostReadable background [
          "000000"
          "ffffff"
        ]
    );

  mix = pct: lib.zipListsWith (a: b: (a * pct + b * (100 - pct) + 50) / 100);
  mixHex =
    pct: a: b:
    lib.concatMapStrings (builtins.elemAt hexBytes) (mix pct (channels a) (channels b));

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
      on = color: ratio color (builtins.head backgrounds);
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

  fillBehind =
    text: steps: color:
    let
      target = mostReadable text [
        "000000"
        "ffffff"
      ];
      on = contrast (luminance (channels text));
      from = channels color;
      to = channels target;
      readable = pct: on (luminance (mix pct from to)) >= 4.5;
      pct = lib.findFirst readable 0 (lib.reverseList (lib.range 0 100));
    in
    lib.toLower (mixHex (lib.max 0 (pct - steps)) color target);

  hoverOf =
    background: text:
    lib.toLower (
      mixHex 85 background (
        if luminance (channels text) < luminance (channels background) then "ffffff" else "000000"
      )
    );
}
