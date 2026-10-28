{
  config,
  lib,
  pkgs,
  ...
}:
let
  realtimeLimitUs = 5000000;

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
  micVolume = "0.25";

  easyeffectsSettings = pkgs.writeShellApplication {
    name = "easyeffects-settings";
    runtimeInputs = [ pkgs.kdePackages.kconfig ];
    text = ''
      rc=''${XDG_CONFIG_HOME:-$HOME/.config}/easyeffects/db/easyeffectsrc
      mkdir -p "$(dirname "$rc")"
      set_key() { kwriteconfig6 --file "$rc" --group "$1" --key "$2" "''${@:3}"; }
      set_key StreamInputs useDefaultInputDevice --type bool false
      set_key StreamInputs inputDevice ${mic}
      set_key EffectsPipelines processAllInputs --type bool false
      set_key EffectsPipelines processAllOutputs --type bool false
      set_key StreamOutputs plugins --delete
      set_key EffectsPipelines bypass --type bool false
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
      wpctl set-default "$source"
      wpctl set-volume "$microphone" ${micVolume}
    '';
  };
in
{
  security.rtkit.args = [ "--rttime-usec-max=${toString realtimeLimitUs}" ];

  services.pipewire.extraConfig =
    let
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
      Restart = lib.mkForce "always";
    };
  };
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
