{ lib, rawScheme }:
translucent:
let
  rgb =
    name:
    lib.concatStringsSep "," [
      rawScheme."${name}-rgb-r"
      rawScheme."${name}-rgb-g"
      rawScheme."${name}-rgb-b"
    ];
  # KDE reads a fourth number as the alpha, from 0 (clear) to 255 (opaque).
  # The Glass Qt style draws windows with these backgrounds, and the Glass
  # KWin effect blurs what shows through.
  rgba = name: alpha: "${rgb name},${toString alpha}";
  kdeColorGroup =
    {
      backgroundNormal,
      backgroundAlternate,
      foregroundNormal,
      groupTranslucent ? false,
    }:
    ''
      BackgroundAlternate=${
        if groupTranslucent then rgba backgroundAlternate 80 else rgb backgroundAlternate
      }
      BackgroundNormal=${if groupTranslucent then rgba backgroundNormal 140 else rgb backgroundNormal}
      DecorationFocus=${rgb "base0D"}
      DecorationHover=${rgb "base0D"}
      ForegroundActive=${rgb "base0D"}
      ForegroundInactive=${rgb "base03"}
      ForegroundLink=${rgb "base0D"}
      ForegroundNegative=${rgb "base08"}
      ForegroundNeutral=${rgb "base09"}
      ForegroundNormal=${rgb foregroundNormal}
      ForegroundPositive=${rgb "base0B"}
      ForegroundVisited=${rgb "base0E"}
    '';
  group = kdeColorGroup;
in
''
  [ColorEffects:Disabled]
  Color=${rgb "base03"}
  ColorAmount=0
  ColorEffect=0
  ContrastAmount=0.65
  ContrastEffect=1
  IntensityAmount=0.1
  IntensityEffect=2

  [ColorEffects:Inactive]
  ChangeSelectionColor=true
  Color=${rgb "base03"}
  ColorAmount=0.025
  ColorEffect=2
  ContrastAmount=0.1
  ContrastEffect=2
  Enable=false
  IntensityAmount=0
  IntensityEffect=0

  [Colors:Button]
  ${group {
    backgroundNormal = "base01";
    backgroundAlternate = "base02";
    foregroundNormal = "base05";
  }}
  [Colors:Complementary]
  ${group {
    backgroundNormal = "base00";
    backgroundAlternate = "base01";
    foregroundNormal = "base05";
  }}
  [Colors:Header]
  ${group {
    backgroundNormal = "base01";
    backgroundAlternate = "base02";
    foregroundNormal = "base05";
  }}
  [Colors:Header][Inactive]
  ${group {
    backgroundNormal = "base00";
    backgroundAlternate = "base01";
    foregroundNormal = "base04";
  }}
  [Colors:Selection]
  ${group {
    backgroundNormal = "base0D";
    backgroundAlternate = "base0C";
    foregroundNormal = "base00";
  }}
  [Colors:Tooltip]
  ${group {
    backgroundNormal = "base01";
    backgroundAlternate = "base02";
    foregroundNormal = "base05";
  }}
  [Colors:View]
  ${group {
    backgroundNormal = "base00";
    backgroundAlternate = "base01";
    foregroundNormal = "base05";
    groupTranslucent = translucent;
  }}
  [Colors:Window]
  ${group {
    backgroundNormal = "base00";
    backgroundAlternate = "base01";
    foregroundNormal = "base05";
    groupTranslucent = translucent;
  }}
  [General]
  ColorScheme=OrucBase16${lib.optionalString translucent "Glass"}
  Name=Oruc Base16${lib.optionalString translucent " Glass"}
  shadeSortColumn=true

  [KDE]
  contrast=4

  [WM]
  activeBackground=${rgb "base01"}
  activeBlend=${rgb "base01"}
  activeForeground=${rgb "base05"}
  inactiveBackground=${rgb "base00"}
  inactiveBlend=${rgb "base00"}
  inactiveForeground=${rgb "base03"}
''
