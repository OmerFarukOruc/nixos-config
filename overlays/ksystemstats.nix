# ksystemstats can keep a sensor subscribed after every client has let it go.
# For the RTX 4070 that keeps `nvidia-smi dmon` running and the GPU awake.
# The patch closes the two ways this happens:
# - A client that subscribes to a sensor twice took two references but gave
#   back one when it unsubscribed or disconnected. Plasma widgets subscribe to
#   some sensors more than once. The patch counts repeat subscriptions instead.
# - A subscribe call that arrived after its client had left, such as Plasma's
#   at logout, created a client the daemon never removed. The patch drops it.
# Upstream src/client.cpp and src/daemon.cpp still have both bugs:
# https://invent.kde.org/plasma/ksystemstats/-/tree/master/src
_final: prev: {
  kdePackages = prev.kdePackages.overrideScope (
    _kfinal: kprev: {
      ksystemstats = kprev.ksystemstats.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [ ./ksystemstats-subscriptions.patch ];
      });
    }
  );
}
