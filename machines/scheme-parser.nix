{ lib }:
path:
let
  file = builtins.unsafeDiscardStringContext (baseNameOf path);
  fail = problem: throw "machines/scheme-parser.nix: ${file}: ${problem}";
  slots = map (i: "base0${lib.toUpper (lib.toHexString i)}") (lib.range 0 15);
  fields = [
    "name"
    "author"
    "variant"
  ];

  scalar =
    key: raw:
    let
      quoted = builtins.match ''"([^"\\]*)"([[:space:]]+#.*)?[[:space:]]*'' raw;
      single = builtins.match "'(([^']|'')*)'([[:space:]]+#.*)?[[:space:]]*" raw;
      plain = lib.trim (builtins.head (builtins.split "[[:space:]]+#" raw));
    in
    if quoted != null then
      builtins.head quoted
    else if single != null then
      builtins.replaceStrings [ "''" ] [ "'" ] (builtins.head single)
    else if builtins.match "[^][{}#&*!|>'\"%@,`[:space:]].*" plain != null then
      plain
    else
      fail "${key} has an unsupported value";

  readLine =
    state: line:
    let
      top = builtins.match "([^[:space:]#][^:]*):[[:space:]]*(.*)" line;
      slot = builtins.match ''[[:space:]]+(base0[0-9A-F]):[[:space:]]*"(#[0-9a-fA-F]{6})"[[:space:]]*(#.*)?'' line;
      blank = builtins.match "[[:space:]]*(#.*)?" line != null;
      key = builtins.head top;
    in
    if top != null then
      state
      // {
        section = key;
      }
      // lib.optionalAttrs (builtins.elem key fields) {
        values = state.values // {
          ${key} = scalar key (builtins.elemAt top 1);
        };
      }
    else if blank || state.section != "palette" then
      state
    else if slot == null then
      fail "palette line `${lib.trim line}` is not a quoted #rrggbb slot"
    else if state.palette ? ${builtins.head slot} then
      fail "${builtins.head slot} repeated"
    else
      state
      // {
        palette = state.palette // {
          ${builtins.head slot} = builtins.elemAt slot 1;
        };
      };

  parsed = builtins.foldl' readLine {
    section = null;
    values = { };
    palette = { };
  } (lib.splitString "\n" (builtins.unsafeDiscardStringContext (builtins.readFile path)));

  value = key: parsed.values.${key} or (fail "${key} missing");
  variant = value "variant";
in
assert builtins.all (slot: parsed.palette ? ${slot} || fail "${slot} missing") slots;
assert
  builtins.elem variant [
    "dark"
    "light"
  ]
  || fail "variant ${variant} is neither dark nor light";
{
  system = "base16";
  slug = lib.removeSuffix ".yaml" file;
  name = value "name";
  author = value "author";
  inherit variant;
  inherit (parsed) palette;
}
