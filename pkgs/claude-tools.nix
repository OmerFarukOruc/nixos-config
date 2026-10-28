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
    find bin -maxdepth 1 -type f -exec cp -t $out/bin {} +
    substitute claude-accounts.sh $out/share/claude-tools/claude-accounts.sh --subst-var-by bin $out/bin
    cp README.md $out/share/claude-tools/
  '';
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
