# Plasma's panel can loop forever, which freezes plasmashell, while something
# is dragged over it. To find the widget under the pointer, the panel steps
# back `layout.rowSpacing` pixels until it hits one. Panel Colorizer applies
# its widget spacing to that layout outside edit mode, and
# home-manager/modules/plasma-panels.nix sets it to 0 for the floating top bar
# of the glass look, so a point between two widgets never moves. The patch
# steps at least one pixel, starts the search no further out than the last
# widget and treats "no widget" as the first position.
# Upstream containments/panel/LayoutManager.js had the loop on master cab933b0
# (2026-11-02). Check these reports before dropping the patch:
# https://bugs.kde.org/show_bug.cgi?id=528228
# https://github.com/luisbocanegra/plasma-panel-colorizer/issues/593
_final: prev: {
  kdePackages = prev.kdePackages.overrideScope (
    _kfinal: kprev: {
      plasma-desktop = kprev.plasma-desktop.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [ ./plasma-desktop-panel-drag-loop.patch ];
      });
    }
  );
}
