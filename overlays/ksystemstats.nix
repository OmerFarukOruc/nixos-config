# ksystemstats can keep a sensor subscribed after every client has let it go.
# For the RTX 4070 that keeps `nvidia-smi dmon` running and the GPU awake.
# The patch closes the two ways this happens:
# - A client that subscribes to a sensor twice took two references but gave
#   back one when it unsubscribed or disconnected. Plasma widgets subscribe to
#   some sensors more than once. The patch counts repeat subscriptions instead.
# - A subscribe call that arrived after its client had left, such as Plasma's
#   at logout, created a client the daemon never removed. The patch drops it.
# Upstream src/client.cpp and src/daemon.cpp had both bugs on master abe3da27
# (2026-11-02). Check these reports before dropping the patch:
# https://bugs.kde.org/show_bug.cgi?id=526594
# https://bugs.kde.org/show_bug.cgi?id=528227
_final: prev: {
  kdePackages = prev.kdePackages.overrideScope (
    _kfinal: kprev: {
      ksystemstats = kprev.ksystemstats.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [ ./ksystemstats-subscriptions.patch ];
      });
    }
  );
}
