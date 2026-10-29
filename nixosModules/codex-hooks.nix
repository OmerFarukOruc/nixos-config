_: {
  environment.etc."codex/hooks.json".text = builtins.toJSON {
    hooks.PreToolUse = [
      {
        matcher = "apply_patch";
        hooks = [
          {
            type = "command";
            command = ''guard="$HOME/.claude/hooks/guard-main-edit.py"; [ ! -x "$guard" ] || exec "$guard"'';
            timeout = 10;
          }
        ];
      }
    ];
  };
}
