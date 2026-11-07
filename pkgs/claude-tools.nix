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
    substituteInPlace src/claude_tools/settings.py --replace-fail @libexec@ $out/libexec/claude-tools
    substituteInPlace libexec/claude-accounts share/claude-tools.sh --replace-fail @bin@ $out/bin
  '';
  postInstall = ''
    install -Dm755 -t $out/libexec/claude-tools libexec/claude-accounts libexec/login-browser libexec/rotate-on-limit
    install -Dm644 -t $out/libexec/claude-tools libexec/config-lock.sh
    install -Dm644 -t $out/share/claude-tools share/claude-tools.sh README.md
  '';
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    export HOME=$TMPDIR
    tools=$out/bin/claude-tools
    $tools --help >/dev/null
    for c in $($tools --complete-words); do
      case $c in accounts | rotate) continue ;; esac
      $tools "$c" --help >/dev/null
      for s in $($tools --complete-words "$c"); do
        case $s in -*) ;; *) $tools "$c" "$s" --help >/dev/null ;; esac
      done
    done
    if grep -rn --exclude=README.md '@bin@\|@libexec@' $out/libexec $out/share $out/lib; then
      echo "a store path placeholder was left in place" >&2
      exit 1
    fi
    runHook postInstallCheck
  '';
}
