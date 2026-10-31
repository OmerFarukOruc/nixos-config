# binaryen 133's wasm-opt refuses the web UI module that wasm-bindgen 0.2.105
# writes for tuliprox 3.2.0 ("parse exception: duplicate export name"), so the
# package fails to build. data-wasm-opt="0" makes trunk skip wasm-opt, which
# only shrinks the module. The override drops out with the next tuliprox
# release.
_final: prev: {
  tuliprox =
    if prev.tuliprox.version == "3.2.0" then
      prev.tuliprox.overrideAttrs (old: {
        postPatch = (old.postPatch or "") + ''
          substituteInPlace frontend/index.html \
            --replace-fail 'data-wasm-opt-params="--all-features"' 'data-wasm-opt="0"'
        '';
      })
    else
      prev.tuliprox;
}
