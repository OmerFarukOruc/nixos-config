# EasyEffects removes noise from the internal microphone with RNNoise. The
# preset loads whenever that microphone is the active input route.
_:
let
  preset = "RNNoise";
  # EasyEffects names an autoload file after the PipeWire node and the
  # description of its active route.
  node = "alsa_input.pci-0000_66_00.6.analog-stereo";
  route = "Internal Microphone";
in
{
  xdg.dataFile = {
    "easyeffects/input/${preset}.json".text = builtins.toJSON {
      input = {
        blocklist = [ ];
        plugins_order = [ "rnnoise#0" ];
        # EasyEffects 8.3 defaults, with the built-in model.
        "rnnoise#0" = {
          bypass = false;
          input-gain = 0.0;
          output-gain = 0.0;
          model-name = "";
          use-standard-model = true;
          enable-vad = false;
          vad-thres = 50.0;
          wet = 0.0;
          release = 20.0;
        };
      };
    };
    "easyeffects/autoload/input/${node}:${route}.json".text = builtins.toJSON {
      device = node;
      device-description = "Ryzen HD Audio Controller Analog Stereo";
      device-profile = route;
      preset-name = preset;
    };
  };
}
