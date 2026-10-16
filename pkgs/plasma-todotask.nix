# Todo Task, a Plasma panel widget for today's tasks and a queue, kept in one
# Markdown file (Documents/todotask/todo.md by default). The widget is QML
# only, so the package copies it into the plasmoid directory. It reaches
# base64, xdg-user-dir and xdg-open through plasmashell's PATH. It names no
# release source, so scripts/update-app.sh skips it; move version and hash by
# hand.
{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "plasma-todotask";
  version = "0.3.0";

  src = fetchFromGitHub {
    owner = "adweb-id";
    repo = "plasma-todotask";
    tag = "v${finalAttrs.version}";
    hash = "sha256-4mACVei4Uy+nZRLBTAIEZ5po12MoLKViyHUYXWl9x8M=";
  };

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    dir=$out/share/plasma/plasmoids/com.adweb.todotask
    mkdir -p $dir
    cp -r metadata.json contents $dir/
    runHook postInstall
  '';

  meta = {
    description = "Today's tasks and a queue in the Plasma panel, stored as Markdown";
    homepage = "https://github.com/adweb-id/plasma-todotask";
    license = lib.licenses.gpl3Plus;
    platforms = lib.platforms.linux;
  };
})
