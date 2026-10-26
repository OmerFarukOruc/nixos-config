{ lib, pkgs, ... }:
{
  # Chromium browsers (Brave included) trust a user's own CAs only through this
  # NSS database, and mkcert -install adds its development CA only to a
  # database that already exists. Brave does not create it, so without this a
  # local HTTPS dev server stays untrusted.
  home.activation.nssDatabase = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if [ ! -f "$HOME/.pki/nssdb/cert9.db" ]; then
      run mkdir -p "$HOME/.pki/nssdb"
      run ${pkgs.nssTools}/bin/certutil -N -d "sql:$HOME/.pki/nssdb" --empty-password
    fi
  '';
}
