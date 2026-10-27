# RootlessKit before 3.0.0 makes the kernel kill rootless dockerd at random.
# Its child process starts dockerd with Pdeathsig SIGKILL, which Linux sends
# when the thread that started dockerd exits (prctl(2), PR_SET_PDEATHSIG). With
# --detach-netns, which dockerd-rootless.sh passes, the builtin port driver
# enters the detached network namespace on a Go thread for each connection to a
# published port and cannot switch that thread back, so Go ends the thread
# (runtime.LockOSThread). When that thread is the one that started dockerd,
# dockerd dies. RootlessKit 3.0.0 starts the command from a thread that stays
# locked until the command exits
# (https://github.com/rootless-containers/rootlesskit/commit/2ca0537e519549158502ff8205ed0f5118d7193e),
# and Docker 29.9.1 ships 3.3.0
# (https://github.com/moby/moby/blob/docker-v29.9.1/hack/dockerfile/install/rootlesskit.installer).
# The override drops out once the locked nixpkgs has 3.0.0 or later. The
# condition sits in the value, because a condition around the attribute name
# reads prev.rootlesskit, whose callPackage reads the final package set, and
# that recurses forever.
_final: prev: {
  rootlesskit =
    if prev.lib.versionOlder prev.rootlesskit.version "3.0.0" then
      prev.rootlesskit.overrideAttrs (
        finalAttrs: _: {
          version = "3.3.0";
          src = prev.fetchFromGitHub {
            owner = "rootless-containers";
            repo = "rootlesskit";
            tag = "v${finalAttrs.version}";
            hash = "sha256-iKP/I5Td+dLr2D+4iaToOpdKjWv/xjdxd4y2o4Gl0h0=";
          };
          vendorHash = "sha256-FTBYVCE0jvAmkKiO+Aqr4IyZ3XDtx9PyMtHc39A3kIk=";
          # The iptables case of this test needs the iptables binary, which the
          # build sandbox does not have. Its nft case skips itself when nft is
          # missing.
          checkFlags = [ "-skip=^TestSourceIPTransparentBackend$/^iptables$" ];
        }
      )
    else
      prev.rootlesskit;
}
