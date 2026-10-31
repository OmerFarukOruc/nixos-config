{ python3Packages, runCommand }:
python3Packages.toPythonModule (
  runCommand "settings-file" { propagatedBuildInputs = [ python3Packages.tomlkit ]; } ''
    install -Dm444 ${./settings_file.py} $out/${python3Packages.python.sitePackages}/settings_file.py
  ''
)
