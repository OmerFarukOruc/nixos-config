# nixpkgs ships IPTVnator 0.24.0. This carries the package changes of
# https://github.com/NixOS/nixpkgs/pull/586562 (0.25.0). Drops out once nixpkgs
# has 0.25.0 or newer.
_final: prev:
let
  inherit (prev) lib;
  replaceOnce =
    from: to: text:
    let
      parts = lib.splitString from text;
    in
    assert lib.assertMsg (builtins.length parts == 2)
      "overlays/iptvnator.nix: expected exactly one `${lib.head (lib.splitString "\n" from)}` in nixpkgs' build script";
    lib.concatStringsSep to parts;
in
{
  iptvnator =
    if lib.versionOlder prev.iptvnator.version "0.25.0" then
      prev.iptvnator.overrideAttrs (
        finalAttrs: old: {
          version = "0.25.0";

          src = prev.fetchFromGitHub {
            owner = "4gray";
            repo = "iptvnator";
            rev = "v${finalAttrs.version}";
            hash = "sha256-/TN5SQsMVkuJq8YPVnrvN4iD0vMGNK1+Cqem4LJrwTU=";
          };

          # The nixpkgs PR adds this patch so @swc/core's native binding cache check passes in the build sandbox.
          patches = [ ./iptvnator-update-swc-core.patch ];

          pnpmDeps = prev.fetchPnpmDeps {
            inherit (finalAttrs)
              pname
              version
              src
              patches
              ;
            pnpm = prev.pnpm_10;
            fetcherVersion = 3;
            hash = "sha256-8lbvagysjaB7YiwQ8lk89Pa0OsHuxiSY9Fp7alTV0CI=";
          };

          # The nixpkgs PR forces the pure-JS sass compiler because the dart child of sass-embedded cannot run in the sandbox.
          env = old.env // {
            NG_BUILD_SASS_EMBEDDED = "0";
          };

          buildPhase = replaceOnce "faketty pnpm run build:backend\n" ''
            faketty pnpm run build:backend
            faketty pnpm nx run web-backend:build
            faketty pnpm nx run web:build-hosted
          '' old.buildPhase;

          postBuild =
            replaceOnce
              ''(["remote-control-web", "electron-backend", "web"] | map({from: "dist/apps/\(.)", to: ., filter: $packFilter}))))''
              ''
                (["remote-control-web", "electron-backend", "web"] | map({from: "dist/apps/\(.)", to: ., filter: $packFilter}))
                         + [{from: "dist/apps/web-backend", to: "hosted-backend", filter: $packFilter},
                            {from: "dist/apps/hosted-pwa/browser", to: "hosted-pwa", filter: $packFilter}]))''
              old.postBuild;
        }
      )
    else
      prev.iptvnator;
}
