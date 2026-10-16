# The scheme of the machine record. The login screen, the boot menu, the
# console and niri read it from here; Home Manager can switch to another
# scheme at run time (home-manager/modules/variants.nix).
import ./theme-module.nix (config: config.oruc.machine.theme.scheme)
