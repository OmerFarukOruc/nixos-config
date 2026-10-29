{
  bash,
  python3Packages,
}:
python3Packages.buildPythonApplication {
  pname = "claude-tools";
  version = "0";
  pyproject = true;
  src = ./claude-tools;
  build-system = [ python3Packages.setuptools ];
  buildInputs = [ bash ];
  postPatch = ''
    substituteInPlace src/claude_tools/settings.py \
      --replace-fail @libexec@ $out/libexec/claude-tools \
      --replace-fail @bin@ $out/bin
    substituteInPlace libexec/claude-accounts share/claude-tools.sh --replace-fail @bin@ $out/bin
  '';
  postInstall = ''
    install -Dm755 -t $out/libexec/claude-tools libexec/claude-accounts libexec/login-browser
    install -Dm644 -t $out/libexec/claude-tools libexec/config-lock.sh
    install -Dm644 -t $out/share/claude-tools share/claude-tools.sh README.md
  '';
  pythonImportsCheck = [ "claude_tools.cli" ];
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    export HOME=$TMPDIR
    while read -r -a cmd; do
      $out/bin/claude-tools "''${cmd[@]}" --help >/dev/null
    done <<'EOF'

    usage
    limit-switch
    limit-switch scan
    limit-switch switch
    agent start
    agent stop
    agent peek
    orch notify
    orch watch
    EOF
    bash -n $out/libexec/claude-tools/claude-accounts $out/libexec/claude-tools/login-browser \
      $out/libexec/claude-tools/config-lock.sh $out/share/claude-tools/claude-tools.sh
    ! grep -rn '@bin@\|@libexec@' $out/libexec $out/share $out/lib
    runHook postInstallCheck
  '';
}
