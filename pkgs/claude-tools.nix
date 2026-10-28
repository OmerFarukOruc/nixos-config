# Omer's Claude Code account tools (pkgs/claude-tools/README.md): claude-accounts
# and claude-usage for several accounts on one machine, claude-rotate behind the
# `claude` shell function, claude-limit-switch for the agents in herdr, and the
# agent-* and orch-* commands that start and watch them. The scripts find each
# other next to themselves in bin. The account list and the shared preferences
# stay in the private dotfiles checkout (CLAUDE_ACCOUNTS_DATA).
{
  bash,
  python3,
  stdenvNoCC,
}:
stdenvNoCC.mkDerivation {
  pname = "claude-tools";
  version = "0";
  src = ./claude-tools;
  buildInputs = [
    bash
    python3
  ];
  dontBuild = true;
  installPhase = ''
    mkdir -p $out/bin $out/share/claude-tools
    cp bin/* $out/bin/
    substitute claude-accounts.sh $out/share/claude-tools/claude-accounts.sh --subst-var-by bin $out/bin
    cp -r README.md tests $out/share/claude-tools/
  '';
  # orch-watch loads agent-peek, and agent-peek loads claude-limit-switch, from
  # their own folder, so its help proves that the Python tools find each other.
  doInstallCheck = true;
  installCheckPhase = ''
    export HOME=$TMPDIR PYTHONDONTWRITEBYTECODE=1
    for tool in agent-start claude-limit-switch claude-usage orch-notify orch-watch; do
      $out/bin/$tool --help >/dev/null
    done
    bash -n $out/bin/claude-accounts $out/share/claude-tools/claude-accounts.sh
    ! grep -n '@bin@' $out/share/claude-tools/claude-accounts.sh
  '';
}
