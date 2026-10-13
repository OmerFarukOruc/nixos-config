# EasyEffects removes noise from the internal microphone with DeepFilterNet and
# equalizes the internal speakers with a convolver. Each preset loads whenever
# its device route is active.
_:
let
  # EasyEffects names an autoload file after the PipeWire node and the
  # description of its active route.
  autoload = pipeline: node: route: preset: {
    "easyeffects/autoload/${pipeline}/${node}:${route}.json".text = builtins.toJSON {
      device = node;
      device-description = "Ryzen HD Audio Controller Analog Stereo";
      device-profile = route;
      preset-name = preset;
    };
  };
  inherit (import ./audio-nodes.nix) mic speakers;

  # A 48 kHz, 526-tap, linear-phase speaker EQ for the GA605W. Its gain peaks at
  # +6.3 dB near 138 Hz and stays above +4 dB down to 20 Hz.
  kernel = "zephyrus-g16-balanced";
in
{
  xdg.dataFile = {
    "easyeffects/input/DeepFilterNet.json".text = builtins.toJSON {
      input = {
        blocklist = [ ];
        plugins_order = [ "deepfilternet#0" ];
        # EasyEffects 8.3 defaults. An attenuation limit of 100 dB does not
        # limit the suppression.
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

    # The convolver looks a kernel up by name in this directory.
    "easyeffects/irs/${kernel}.irs".source = ./speaker-eq.wav;

    "easyeffects/output/Speakers.json".text = builtins.toJSON {
      output = {
        blocklist = [ ];
        plugins_order = [
          "convolver#0"
          "filter#0"
          "limiter#0"
        ];
        "convolver#0" = {
          bypass = false;
          # Autogain only scales the kernel down by 0.6 dB. The input gain
          # covers the 6.3 dB peak of the kernel, and the limiter catches the
          # rest.
          autogain = false;
          input-gain = -6.5;
          output-gain = 0.0;
          kernel-name = kernel;
          ir-width = 100;
          dry = -100.0;
          wet = 0.0;
        };
        # A 24 dB per octave Butterworth high-pass. In Notebookcheck's pink
        # noise test of the GA605WV, the speakers lose 14 dB from 100 Hz to
        # 80 Hz, and the kernel boosts that range by more than 4 dB.
        # https://www.notebookcheck.net/Asus-ROG-Zephyrus-G16-2024-review-The-slim-gaming-laptop-now-with-AMD-Zen-5.877382.0.html
        "filter#0" = {
          bypass = false;
          input-gain = 0.0;
          output-gain = 0.0;
          type = "High-pass";
          mode = "BWC (BT)";
          equal-mode = "IIR";
          slope = "x2";
          frequency = 80.0;
          width = 4.0;
          quality = 0.0;
          gain = 0.0;
          balance = 0.0;
          decramp = "Off";
        };
        "limiter#0" = {
          bypass = false;
          input-gain = 0.0;
          output-gain = 0.0;
          mode = "Herm Thin";
          oversampling = "True Peak/24 bit";
          dithering = "None";
          sidechain-type = "Internal";
          lookahead = 5.0;
          attack = 5.0;
          release = 5.0;
          threshold = -1.0;
          gain-boost = false;
          sidechain-preamp = 0.0;
          stereo-link = 100.0;
          alr = false;
        };
      };
    };

    # Headphones share the speaker node, and EasyEffects keeps the last preset
    # when a route has no autoload file.
    "easyeffects/output/Flat.json".text = builtins.toJSON {
      output = {
        blocklist = [ ];
        plugins_order = [ ];
      };
    };
  }
  // autoload "input" mic "Internal Microphone" "DeepFilterNet"
  // autoload "output" speakers "Speakers" "Speakers"
  // autoload "output" speakers "Headphones" "Flat";
}
