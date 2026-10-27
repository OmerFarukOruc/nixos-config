# One virtio disk. The ESP is 4 GiB as on the other hosts, because every kept
# generation stores a kernel and an initrd on it. Limine's BIOS stage needs the
# 1 MiB partition of type EF02 on a GPT disk, and the firmware of a UEFI boot
# needs the ESP, so the same disk boots under either firmware
# (oruc.machine.biosDevice).
_: {
  disko.devices.disk.main = {
    type = "disk";
    device = "/dev/vda";
    content = {
      type = "gpt";
      partitions = {
        bios = {
          size = "1M";
          type = "EF02";
          priority = 1;
        };
        esp = {
          size = "4G";
          type = "EF00";
          priority = 2;
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [
              "fmask=0077"
              "dmask=0077"
            ];
          };
        };
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };
}
