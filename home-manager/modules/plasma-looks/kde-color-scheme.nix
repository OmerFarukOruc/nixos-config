{ lib, rawScheme }:
translucent:
let
  contrast = import ../../../nixosModules/contrast.nix { inherit lib; };
  scheme = rawScheme;
  rgb = contrast.decimal;
  buttonSeparation = 1.3;
  button = contrast.raisedSurface scheme scheme.base00 buttonSeparation;
  buttonAlternate = contrast.raisedSurface scheme button buttonSeparation;
  text = contrast.legibleOn scheme [
    scheme.base00
    button
  ] scheme.base05;
  # KDE reads a fourth number as the alpha, from 0 (clear) to 255 (opaque).
  # The Glass Qt style draws windows with these backgrounds, and the Glass
  # KWin effect blurs what shows through.
  rgba = color: alpha: "${rgb color},${toString alpha}";
  group =
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
      DecorationFocus=${rgb scheme.base0D}
      DecorationHover=${rgb scheme.base0D}
      ForegroundActive=${rgb scheme.base0D}
      ForegroundInactive=${rgb scheme.base03}
      ForegroundLink=${rgb scheme.base0D}
      ForegroundNegative=${rgb scheme.base08}
      ForegroundNeutral=${rgb scheme.base09}
      ForegroundNormal=${rgb foregroundNormal}
      ForegroundPositive=${rgb scheme.base0B}
      ForegroundVisited=${rgb scheme.base0E}
    '';
in
''
  [ColorEffects:Disabled]
  Color=${rgb scheme.base03}
  ColorAmount=0
  ColorEffect=0
  ContrastAmount=0.65
  ContrastEffect=1
  IntensityAmount=0.1
  IntensityEffect=2

  [ColorEffects:Inactive]
  ChangeSelectionColor=true
  Color=${rgb scheme.base03}
  ColorAmount=0.025
  ColorEffect=2
  ContrastAmount=0.1
  ContrastEffect=2
  Enable=false
  IntensityAmount=0
  IntensityEffect=0

  [Colors:Button]
  ${group {
    backgroundNormal = button;
    backgroundAlternate = buttonAlternate;
    foregroundNormal = text;
  }}
  [Colors:Complementary]
  ${group {
    backgroundNormal = scheme.base00;
    backgroundAlternate = scheme.base01;
    foregroundNormal = scheme.base05;
  }}
  [Colors:Header]
  ${group {
    backgroundNormal = scheme.base01;
    backgroundAlternate = scheme.base02;
    foregroundNormal = scheme.base05;
  }}
  [Colors:Header][Inactive]
  ${group {
    backgroundNormal = scheme.base00;
    backgroundAlternate = scheme.base01;
    foregroundNormal = scheme.base04;
  }}
  [Colors:Selection]
  ${group {
    backgroundNormal = scheme.base0D;
    backgroundAlternate = scheme.base0C;
    foregroundNormal = scheme.base00;
  }}
  [Colors:Tooltip]
  ${group {
    backgroundNormal = scheme.base01;
    backgroundAlternate = scheme.base02;
    foregroundNormal = scheme.base05;
  }}
  [Colors:View]
  ${group {
    backgroundNormal = scheme.base00;
    backgroundAlternate = scheme.base01;
    foregroundNormal = scheme.base05;
    groupTranslucent = translucent;
  }}
  [Colors:Window]
  ${group {
    backgroundNormal = scheme.base00;
    backgroundAlternate = scheme.base01;
    foregroundNormal = text;
    groupTranslucent = translucent;
  }}
  [General]
  ColorScheme=OrucBase16${lib.optionalString translucent "Glass"}
  Name=Oruc Base16${lib.optionalString translucent " Glass"}
  shadeSortColumn=true

  [KDE]
  contrast=4

  [WM]
  activeBackground=${rgb scheme.base01}
  activeBlend=${rgb scheme.base01}
  activeForeground=${rgb scheme.base05}
  inactiveBackground=${rgb scheme.base00}
  inactiveBlend=${rgb scheme.base00}
  inactiveForeground=${rgb scheme.base03}
''
