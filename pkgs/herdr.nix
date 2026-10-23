# herdr 0.9.4, which llm-agents does not package yet. Once llm-agents' herdr
# reaches 0.9.4, the version check below passes it through unchanged; then
# delete this file and its use in nixosModules/home-manager.nix.
{
  lib,
  fetchFromGitHub,
  rustPlatform,
  herdr,
}:
if lib.versionAtLeast herdr.version "0.9.4" then
  herdr
else
  herdr.overrideAttrs (
    finalAttrs: _old: {
      version = "0.9.4";
      src = fetchFromGitHub {
        owner = "herdrdev";
        repo = "herdr";
        tag = "v${finalAttrs.version}";
        hash = "sha256-tbOVXxQCA/suZ+My71B5laNZhEpK46YLYUs7H8tdysY=";
      };
      # buildRustPackage reads cargoHash before overrideAttrs applies, so the
      # vendored crates are replaced whole.
      cargoDeps = rustPlatform.fetchCargoVendor {
        inherit (finalAttrs) pname version src;
        hash = "sha256-IPsukFZI+VARH2e4I3dNe6pD8f3NaC3WtLiylfl/qQA=";
      };
      # 0.9.4 vendors the same libghostty-vt Zig packages as 0.9.3, so
      # llm-agents' zigDeps stays.
    }
  )
