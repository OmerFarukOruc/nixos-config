{
  lib,
  buildGoLatestModule,
  fetchFromGitHub,
}:
# go.mod requires Go 1.27.3.
buildGoLatestModule (finalAttrs: {
  pname = "linctl";
  version = "0.28.0";

  src = fetchFromGitHub {
    owner = "KyaniteHQ";
    repo = "linctl";
    tag = "v${finalAttrs.version}";
    hash = "sha256-k+m/tuj/br6hKXU0w/FMtT5LisBvPGuZqTD3ujD7vn8=";
  };

  vendorHash = "sha256-gsk000V/rEPGpkcPV9I0ky2vV4ummnEAFcCS6e4EKWs=";

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
