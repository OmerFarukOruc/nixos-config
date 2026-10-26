# Home Manager installs mcp-nixos as Claude Code's NixOS MCP server. Once
# python3Packages.mcp reaches 2.x, nixpkgs marks fastmcp-slim broken, and
# mcp-nixos, which needs it, stops every host's evaluation. While fastmcp-slim
# is broken, this builds mcp-nixos against mcp_1, as nixpkgs does from
# https://github.com/NixOS/nixpkgs/commit/3201cb18ddc06d87e402775e385251e3102c5b74
# on, and it drops out once the locked mcp-nixos names mcp_1 itself. The condition
# sits in the value, because python3Packages reads the final package set, so a
# condition around the attribute names recurses forever.
_final: prev:
let
  source = builtins.readFile (prev.path + "/pkgs/by-name/mc/mcp-nixos/package.nix");
in
{
  mcp-nixos =
    if
      prev.python3Packages ? mcp_1
      && (prev.python3Packages.fastmcp-slim.meta.broken or false)
      && !prev.lib.hasInfix "mcp_1" source
    then
      prev.mcp-nixos.override {
        python3Packages = prev.python3Packages.overrideScope (
          pyFinal: _: {
            mcp = pyFinal.mcp_1;
          }
        );
      }
    else
      prev.mcp-nixos;
}
