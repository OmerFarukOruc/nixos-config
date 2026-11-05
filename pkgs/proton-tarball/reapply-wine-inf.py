            self.upgrade_pfx(old_ver)

            # SPDX-License-Identifier: MIT
            # Copyright (c) 2026 Keenan Weaver
            # https://github.com/keenanweaver/nix-config/blob/74fabca760825858fbf142a3d50b3f7701818f93/pkgs/proton-wineland/reapply-wine-inf.py
            applied_inf = self.prefix_dir + ".nix-wine-inf-sha256"
            try:
                with open(applied_inf, "r") as f:
                    applied = f.read().strip()
            except OSError:
                applied = None
            if applied != "@wineInfSha256@" and os.path.isdir(self.prefix_dir):
                if file_exists(self.prefix_dir + ".update-timestamp", follow_symlinks=False):
                    os.remove(self.prefix_dir + ".update-timestamp")
                with open(applied_inf, "w") as f:
                    f.write("@wineInfSha256@\n")
