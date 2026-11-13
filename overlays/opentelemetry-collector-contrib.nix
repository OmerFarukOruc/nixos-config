# opentelemetry-collector-contrib 0.155.0 does not build with Go 1.27, the
# default Go of nixpkgs since its move to Go 1.27: its pinned
# github.com/cockroachdb/swiss stops at Go 1.26 and fails with "undefined:
# hashFn" (Go 1.27 support: https://github.com/cockroachdb/swiss/commit/aa852fb3).
# Versions up to 0.164.0 compiled with Go 1.27 still panic at start, because
# asapauthextension pulls in SermoDigital/jose
# (https://github.com/open-telemetry/opentelemetry-collector-contrib/issues/51868);
# the 0.165.0 manifest leaves that extension out. nixpkgs fixes the first
# problem with the update that
# https://github.com/NixOS/nixpkgs/pull/581121 makes. The distributions
# compile with Go 1.26 until the locked nixpkgs has 0.165.0 or later. The
# condition sits in the value, because a condition around the attribute name
# reads prev.opentelemetry-collector-releases, whose callPackage reads the
# final package set, and that recurses forever.
_final: prev: {
  opentelemetry-collector-releases =
    if
      prev.lib.versionOlder prev.opentelemetry-collector-releases.otelcol-contrib.version "0.165.0"
    then
      prev.opentelemetry-collector-releases.override { buildGoModule = prev.buildGo126Module; }
    else
      prev.opentelemetry-collector-releases;
}
