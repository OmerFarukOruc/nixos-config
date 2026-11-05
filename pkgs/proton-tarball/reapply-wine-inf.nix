# wineboot applies a new wine.inf to an existing prefix only when the file's
# mtime differs from the prefix's .update-timestamp, and every file in the Nix
# store has the same mtime. https://github.com/NixOS/nixpkgs/pull/581490
''
  substituteInPlace "$steamcompattool/proton" \
    --replace-fail "            self.upgrade_pfx(old_ver)" "$(cat ${./reapply-wine-inf.py})"
  substituteInPlace "$steamcompattool/proton" \
    --replace-fail "@wineInfSha256@" "$(sha256sum "$steamcompattool/files/share/wine/wine.inf" | cut -d' ' -f1)"
''
