{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:
buildGoModule (finalAttrs: {
  pname = "linctl";
  version = "0.27.0";

  src = fetchFromGitHub {
    owner = "KyaniteHQ";
    repo = "linctl";
    tag = "v${finalAttrs.version}";
    hash = "sha256-wsWMRpsuzM/lJqAb0CYp5hcyZelHgGKqt7JxJ9U2IY8=";
  };

  vendorHash = "sha256-zG/rx81vwpQdsJA2s90Jmki2QiU2fUMhLLitIaYDYmw=";

  subPackages = [ "cmd/linctl" ];

  env.CGO_ENABLED = 0;

  # The flags of the upstream release build (.goreleaser.yaml).
  ldflags = [
    "-s"
    "-w"
    "-X main.version=${finalAttrs.version}"
  ];

  meta = {
    description = "Linear CLI with pinned workspace and team targets";
    homepage = "https://github.com/KyaniteHQ/linctl";
    license = lib.licenses.mit;
    mainProgram = "linctl";
  };
})
