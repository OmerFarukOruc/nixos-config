# Audio, recording and transcription on rog.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  # rtkit's own limit is 200 ms of CPU time without a blocking call.
  realtimeLimitUs = 5000000;

  # Only the RTX 4070's architecture, so the CUDA kernels build in one pass.
  whisper-cpp = pkgs.pkgsForCudaArch.sm_89.whisper-cpp;
  whisperModel = pkgs.fetchurl {
    url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo.bin";
    hash = "sha256-H8cPd0046xaZk6w5Huo1fvR8iHV+9y7llDh5t+jivGk=";
  };
  whisper-v3 = pkgs.writeShellApplication {
    name = "whisper-v3";
    text = ''exec ${lib.getExe' whisper-cpp "whisper-cli"} -m ${whisperModel} "$@"'';
  };
in
{
  security.rtkit.args = [ "--rttime-usec-max=${toString realtimeLimitUs}" ];

  services.pipewire.extraConfig =
    let
      # module-rt merges this section into its arguments. rtkit caps the
      # priority at its maximum of 20, so only the CPU time limit changes.
      rtArgs."module.rt.args" = {
        "rt.time.soft" = realtimeLimitUs;
        "rt.time.hard" = realtimeLimitUs;
      };
    in
    {
      pipewire = {
        "10-clock"."context.properties" = {
          "default.clock.rate" = 44100;
          "default.clock.allowed-rates" = [
            44100
            48000
            88200
            96000
            192000
          ];
          "default.clock.quantum" = 512;
          "default.clock.min-quantum" = 256;
          "default.clock.max-quantum" = 2048;
        };
        "20-realtime" = rtArgs;
      };
      pipewire-pulse."20-realtime" = rtArgs;
    };

  programs.obs-studio = {
    enable = true;
    plugins = with pkgs.obs-studio-plugins; [
      # keep-sorted start
      input-overlay
      obs-mute-filter
      obs-vkcapture
      wlrobs
      # keep-sorted end
    ];
  };
  # Installed, not loaded at boot: a loaded v4l2loopback shows up as a camera
  # in every app. OBS loads it on Start Virtual Camera through pkexec, which
  # needs the setuid wrapper. OBS finds the module only after a reboot into a
  # system that has it.
  boot.extraModulePackages = [ config.boot.kernelPackages.v4l2loopback ];
  security.polkit.enablePkexecWrapper = true;

  environment.systemPackages = [
    whisper-cpp
    whisper-v3
  ];
}
