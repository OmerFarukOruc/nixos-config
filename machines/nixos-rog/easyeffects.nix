_:
let
  autoload = pipeline: node: route: preset: {
    "easyeffects/autoload/${pipeline}/${node}:${route}.json".text = builtins.toJSON {
      device = node;
      device-description = "Ryzen HD Audio Controller Analog Stereo";
      device-profile = route;
      preset-name = preset;
    };
  };
  inherit (import ./audio-nodes.nix) mic;
in
{
  xdg.dataFile = {
    "easyeffects/input/DeepFilterNet.json".text = builtins.toJSON {
      input = {
        blocklist = [ ];
        plugins_order = [ "deepfilternet#0" ];
        "deepfilternet#0" = {
          bypass = false;
          input-gain = 0.0;
          output-gain = 0.0;
          attenuation-limit = 100.0;
          min-processing-threshold = -10.0;
          max-erb-processing-threshold = 30.0;
          max-df-processing-threshold = 20.0;
          min-processing-buffer = 0;
          post-filter-beta = 0.02;
        };
      };
    };

  }
  // autoload "input" mic "Internal Microphone" "DeepFilterNet";
}
