{ scheme, theme }:
let
  color = scheme.withHashtag;
in
''
  layout {
      focus-ring {
          active-color "${color.base0D}"
          inactive-color "${color.base03}"
          urgent-color "${color.base08}"
      }
      border {
          active-color "${color.base0D}"
          inactive-color "${color.base03}"
          urgent-color "${color.base08}"
      }
      insert-hint {
          color "${color.base0D}80"
      }
  }

  overview {
      backdrop-color "${color.base00}"
  }

  cursor {
      xcursor-theme "${theme.cursor.name}"
      xcursor-size ${toString theme.cursor.size}
  }
''
