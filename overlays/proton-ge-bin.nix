_final: prev: {
  proton-ge-bin = prev.proton-ge-bin.overrideAttrs (old: {
    preFixup = old.preFixup + ''
      rm "$steamcompattool/proton"
      cp "$src/proton" "$steamcompattool/proton"
      ${import ../pkgs/proton-tarball/reapply-wine-inf.nix}
    '';
  });
}
