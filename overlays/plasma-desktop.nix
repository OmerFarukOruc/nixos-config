# Plasma's panel can loop forever, which freezes plasmashell, while something
# is dragged over it. To find the widget under the pointer, the panel steps
# back `layout.rowSpacing` pixels until it hits one. Panel Colorizer applies
# its widget spacing to that layout outside edit mode, and
# home-manager/modules/plasma-panels.nix sets it to 0 for the floating top bar
# of the glass look, so a point between two widgets never moves. The patch
# steps at least one pixel, starts the search no further out than the last
# widget and treats "no widget" as the first position.
# Upstream containments/panel/LayoutManager.js still has the loop:
# https://invent.kde.org/plasma/plasma-desktop/-/blob/master/containments/panel/LayoutManager.js
_final: prev: {
  kdePackages = prev.kdePackages.overrideScope (
    _kfinal: kprev: {
      plasma-desktop = kprev.plasma-desktop.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [ ./plasma-desktop-panel-drag-loop.patch ];
      });
    }
  );
}
