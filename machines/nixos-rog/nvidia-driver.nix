{
  version = "615.78.08";
  sha256_64bit = "sha256-Pj9t3cLudnoIGFMAr3vjyyhuznZpjS3eNSRZl4LQf/4=";
  openSha256 = "sha256-HBINiOjL0ZJLIAJeNIBYHBnwgUXtNwPPtnFpAI1YwF4=";
  settingsSha256 = "sha256-inDRpG02sdDgHmlqgu/DsgK8OFdOt1fZIYyXdhlGC/c=";
  persistencedSha256 = "sha256-RzeR6Ldct6MUxjnXRyThdh5Y3jjMehTVg85MtwuWNX4=";
  # Defers NVPCF ACPI notifications that wake a runtime-suspended GPU on each
  # battery drop. The two commits of the upstream change are kept locally so
  # a rewritten pull request cannot break a rebuild. Drop them when a driver
  # release includes https://github.com/NVIDIA/open-gpu-kernel-modules/pull/1299.
  patchesOpen = [
    ./nvidia-patches/nvidia-nvpcf-refcount.patch
    ./nvidia-patches/nvidia-nvpcf-defer.patch
  ];
}
