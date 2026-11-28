{
  lib,
  buildGoLatestModule,
  fetchFromGitHub,
}:
# go.mod requires Go 1.27.3.
buildGoLatestModule (finalAttrs: {
  pname = "linctl";
  version = "0.28.1";

  src = fetchFromGitHub {
    owner = "KyaniteHQ";
    repo = "linctl";
    tag = "v${finalAttrs.version}";
    hash = "sha256-8WMlOrRd7O5YEpsrzfecQtjjezRy2vBvZfv3Rq+dsI0=";
  };

  vendorHash = "sha256-3uCsXZnV2bOQVykF6q3wbjd260gcfakWPsqYSGgEzhY=";

  subPackages = [ "cmd/linctl" ];

  env.CGO_ENABLED = 0;

  # The upstream release build (.goreleaser.yaml) also sets main.commit and
  # main.date, so `linctl --version` prints "unknown" for both.
  ldflags = [
    "-s"
    "-w"
    "-X main.version=${finalAttrs.version}"
  ];

  passthru.githubRepo = "KyaniteHQ/linctl";

  meta = {
    description = "Linear CLI with pinned workspace and team targets";
    homepage = "https://github.com/KyaniteHQ/linctl";
    license = lib.licenses.mit;
    mainProgram = "linctl";
  };
})
