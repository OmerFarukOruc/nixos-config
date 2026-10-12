{ config, lib, ... }:
let
  meters =
    columns:
    with config.lib.htop;
    leftMeters [
      (bar "LeftCPUs${toString columns}")
      (bar "Memory")
      (bar "Swap")
      (text "DiskIO")
      (text "NetworkIO")
    ]
    // rightMeters [
      (bar "RightCPUs${toString columns}")
      (text "Blank")
      (text "Tasks")
      (text "LoadAverage")
      (text "Systemd")
    ];
in
{
  options.oruc.htop.cpuColumns = lib.mkOption {
    # htop has CPU meters in 2, 4 and 8 columns only.
    type = lib.types.enum [
      2
      4
      8
    ];
    default = 2;
    description = "CPU meter columns on each side of htop. A host with more than 16 threads sets 4.";
  };

  config.programs.htop = {
    enable = true;
    settings = {
      hide_kernel_threads = 0;
      hide_userland_threads = 1;
      show_thread_names = 1;
      show_program_path = 1;
      find_comm_in_cmdline = 1;
      strip_exe_from_cmdline = 1;
      sort_key = config.lib.htop.fields.PERCENT_CPU;
      sort_direction = -1;
    }
    // meters config.oruc.htop.cpuColumns;
  };
}
