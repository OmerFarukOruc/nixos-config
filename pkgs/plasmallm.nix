# PlasmaLLM, a Plasma panel widget that chats with Ollama, LM Studio, Claude,
# OpenAI, Gemini or any OpenAI-compatible API, and lets the model call tools
# such as read_file and write_file after the user approves each call. The
# widget is QML and JavaScript, and the repository commits the compiled
# translations, so the package copies package/ as upstream's release zip does,
# without the .po sources. Tools run their commands through plasmashell's PATH
# (curl, bash, notify-send, xdg-open). It names no release source, so
# scripts/update-app.sh skips it; move version and hash by hand.
{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "plasmallm";
  version = "3.2.0";

  src = fetchFromGitHub {
    owner = "joshuaeroman";
    repo = "plasmallm";
    tag = finalAttrs.version;
    hash = "sha256-2OI5sBYF5FbBqjCVLN9YvcQc1BHmcliJvSa8W501cOw=";
  };

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    dir=$out/share/plasma/plasmoids/com.joshuaroman.plasmallm
    mkdir -p $dir
    cp -r package/. $dir/
    rm $dir/contents/locale/*.po $dir/contents/locale/*.pot
    runHook postInstall
  '';

  meta = {
    description = "Chat with local or cloud LLMs from the Plasma panel, with tool calling";
    homepage = "https://github.com/joshuaeroman/plasmallm";
    license = lib.licenses.gpl2Plus;
    platforms = lib.platforms.linux;
  };
})
