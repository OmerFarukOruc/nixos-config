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

  inherit (import ./audio-nodes.nix) mic;
  # wpctl's volume for the internal microphone. At 1.0 the codec adds 60 dB
  # (Capture +30 dB and Internal Mic Boost +30 dB), and speech clips.
  # scripts/mic-ab-on-rog.sh on 2026-10-13: speech clipped 36726 samples at
  # 0.45 and peaked at -3.2 dBFS at 0.3; at 0.25 the 60 s A/B take peaked at
  # -5.2 dBFS with no clipped samples.
  micVolume = "0.25";

  # EasyEffects saves easyeffectsrc while it runs, so a store link would stop
  # every save. This sets only the keys below before each start.
  easyeffectsSettings = pkgs.writeShellApplication {
    name = "easyeffects-settings";
    runtimeInputs = [ pkgs.kdePackages.kconfig ];
    text = ''
      rc=''${XDG_CONFIG_HOME:-$HOME/.config}/easyeffects/db/easyeffectsrc
      mkdir -p "$(dirname "$rc")"
      set_key() { kwriteconfig6 --file "$rc" --group "$1" --key "$2" "''${@:3}"; }
      # A pinned input keeps the pipeline on the raw microphone while
      # HushMic's source is the default source.
      set_key StreamInputs useDefaultInputDevice --type bool false
      set_key StreamInputs inputDevice ${mic}
      # Apps reach EasyEffects' source only when they pick it. With
      # processAllInputs, EasyEffects also moved HushMic's capture stream to
      # its own source, past a blocklist entry for it, so HushMic heard
      # EasyEffects' output.
      set_key EffectsPipelines processAllInputs --type bool false
      # No output effects, so apps play to the speakers directly. An empty
      # output pipeline is the default.
      set_key EffectsPipelines processAllOutputs --type bool false
      set_key StreamOutputs plugins --delete
      set_key EffectsPipelines bypass --type bool false
      # The pipeline unlinks 10 s after the last app stops recording. Linked
      # all the time, DeepFilterNet took 19 % of a core with nothing
      # recording (2026-10-13). With bypass on, EasyEffects does not link the
      # pipeline again, so the next app records silence until bypass is off.
      set_key EffectsPipelines inactivityTimerEnable --type bool true
    '';
  };

  micDefaultSource = pkgs.writeShellApplication {
    name = "mic-default-source";
    runtimeInputs = [
      pkgs.jq
      pkgs.pipewire
      pkgs.wireplumber
    ];
    text = ''
      node_id() {
        pw-dump | jq -r --arg name "$1" \
          'first(.[] | select(.type == "PipeWire:Interface:Node" and .info.props."node.name" == $name) | .id) // empty'
      }
      # HushMic creates its source a moment after its unit starts.
      for _ in $(seq 30); do
        source=$(node_id hushmic_source)
        microphone=$(node_id ${mic})
        [[ -n $source && -n $microphone ]] && break
        sleep 1
      done
      if [[ -z $source || -z $microphone ]]; then
        echo "hushmic_source or ${mic} did not appear within 30 s." >&2
        exit 1
      fi
      # WirePlumber keeps this choice in its state. While HushMic is not
      # running, it falls back to an earlier default it remembers, such as
      # easyeffects_source, or else to the raw microphone.
      wpctl set-default "$source"
      wpctl set-volume "$microphone" ${micVolume}
    '';
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
  # Installed, not loaded at boot, because a loaded v4l2loopback shows up as a
  # camera in every app. OBS loads it on Start Virtual Camera through pkexec,
  # which needs the setuid wrapper. OBS finds the module only after a reboot
  # into a system that has it.
  boot.extraModulePackages = [ config.boot.kernelPackages.v4l2loopback ];
  security.polkit.enablePkexecWrapper = true;

  environment.systemPackages = [
    whisper-cpp
    whisper-v3
  ];

  systemd.user.services.easyeffects = lib.mkIf config.oruc.machine.features.audioEffects {
    serviceConfig = {
      ExecStartPre = [ (lib.getExe easyeffectsSettings) ];
      # A quit from the tray or the window exits 0, and only a start of this
      # unit resets bypass. While the unit runs, a launch from the app menu
      # opens the running instance's window.
      Restart = lib.mkForce "always";
    };
  };
  # Apps that record from the default source get HushMic's denoised
  # microphone. In the 2026-10-13 A/B take, HushMic cut silence and typing by
  # 73 to 75 dB and EasyEffects' DeepFilterNet by 5 to 8 dB, and both kept
  # speech within 1 dB. It runs again with every HushMic start.
  systemd.user.services.mic-default-source = {
    description = "Make HushMic's source the default and set the microphone level";
    after = [ "hushmic.service" ];
    partOf = [ "hushmic.service" ];
    wantedBy = [ "hushmic.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = lib.getExe micDefaultSource;
    };
  };
  # A program that makes the raw microphone the default source takes the
  # denoising away from every app until the next HushMic start. On 2026-10-16
  # one did so as a Bluetooth headset connected, and no log named it. While
  # HushMic's source exists, this hook turns that choice into HushMic; every
  # other source stays a valid choice.
  services.pipewire.wireplumber.extraScripts."hushmic-default.lua" = ''
    -- WirePlumber can restore the saved choice before it loads this script,
    -- so the script checks when the metadata or HushMic's source appears and
    -- on every later change.
    local key = "default.configured.audio.source"
    local metadata_om = ObjectManager {
      Interest { type = "metadata", Constraint { "metadata.name", "=", "default" } },
    }
    local hushmic_om = ObjectManager {
      Interest { type = "node", Constraint { "node.name", "=", "hushmic_source" } },
    }

    local function redirect ()
      local metadata = metadata_om:lookup ()
      local value = metadata and metadata:find (0, key)
      if value and hushmic_om:lookup ()
          and Json.Raw (value):parse ().name == "${mic}" then
        metadata:set (0, key, "Spa:String:JSON",
          Json.Object { name = "hushmic_source" }:to_string ())
      end
    end

    metadata_om:connect ("object-added", function (_, metadata)
      metadata:connect ("changed", function (_, subject, changed_key)
        if subject == 0 and changed_key == key then
          redirect ()
        end
      end)
      redirect ()
    end)
    hushmic_om:connect ("object-added", redirect)
    metadata_om:activate ()
    hushmic_om:activate ()
  '';
  services.pipewire.wireplumber.extraConfig."90-hushmic-default" = {
    "wireplumber.components" = [
      {
        name = "hushmic-default.lua";
        type = "script/lua";
        provides = "custom.hushmic-default";
      }
    ];
    "wireplumber.profiles".main."custom.hushmic-default" = "required";
  };
}
