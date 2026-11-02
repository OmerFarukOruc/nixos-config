{ python3 }:
python3.withPackages (ps: [
  ps.pillow
  ps.pyyaml
])
