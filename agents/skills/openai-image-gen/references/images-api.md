# Images API

Use the key for the selected OpenAI API project. If the SDK environment specifies an organization or project override, ensure it belongs to the chosen billing context before sending. The helper reads `OPENAI_API_KEY`. When the user has identified a protected key file, load it into the command environment with shell tracing off. For example, prefix the command with `OPENAI_API_KEY="$(< "$key_file")"` where `key_file` holds the file path (on a host using the local OpenAI key convention, `key_file="$HOME/.config/openai/key"`). Keep the key out of arguments, prompts, and logs.

Generate one PNG with the chosen settings and an unused output path. The helper uses the official OpenAI Python SDK with automatic retries disabled. Use Python with `openai` and `pillow` installed, or run it with uv:

```bash
uv run --no-project --with openai --with pillow python "$SKILL_DIR/scripts/images_api.py" \
  --image-model gpt-image-2.6-flare --quality low --size 1536x864 \
  --prompt 'A red ceramic cup on a pale blue table. Leave room on the left for a title.' \
  --output ./slide-draft.png
```

For an edit, pass the target as the first `--reference`. Add another `--reference` for each additional input in prompt order. The helper sends these files through the edits endpoint. For example, add `--reference ./slide-draft.png --complexity low` with the prompt “Change only the cup to yellow. Preserve the framing, shadows, and empty space.” Use `--prompt-file` for a longer brief or `--background transparent` for a cutout.

The helper prints decoded dimensions and transparency, requested model and quality, and returned quality when available. Inspect the saved PNG before delivering. Exit 5 retains the returned file for inspection when the format or settings could not be verified. It does not authorize a retry. If a connection fails after sending, the billing outcome can be unknown. Report the failure before another attempt.

A live request on 2026-11-24 returned a 1024×1024 PNG and reported low quality with Flare requested. The edit request was checked locally with the SDK; a live edit was outside that check.

For requests beyond the PNG helper, use the official SDK on the selected API project with the same retry and credential handling. Follow the [Images API examples](https://developers.openai.com/api/docs/guides/image-generation) for the requested format or edit control:

- For SVG, use generations, a single output, and no streaming. Decode the returned base64 to an SVG file and inspect the rendered result.
- For an animated GIF, use generations or edits and the guide’s GIF-specific sizes, frame count, and frame duration. Inspect the animation and loop.
- For a markup-guided edit, supply a transparent PNG overlay matching the first image’s dimensions. A mask identifies a region through its alpha channel. Describe the change and what to preserve. Omit `input_fidelity` on Images 2.6 edits.

## 4K Sunburst cost comparison

Two standard Images API generations on 2026-11-24 used Sunburst, an identical text-only prompt for a vintage camera, high complexity, and opaque PNG output. Both PNGs measured 3840×2160 (8,294,400 pixels), and each response reported the requested quality.

| Quality | Calculator output estimate | API output tokens | Output cost from usage | Total with prompt |
| --- | ---: | ---: | ---: | ---: |
| xhigh | $0.17790 | 5,930 | $0.17790 | $0.178645 |
| max | $0.40026 | 13,342 | $0.40026 | $0.401005 |

Each request used 149 text input tokens and zero image input tokens. At $5 per million text input tokens, the prompt added $0.000745 per image. Image output cost $30 per million tokens. Totals use the published standard rates before credits. The responses supplied usage counts; the account invoice and credit balance were not checked. [Cost calculator](https://developers.openai.com/api/docs/guides/image-generation#calculating-costs) and [standard pricing](https://developers.openai.com/api/docs/pricing#image-generation).

At these settings max cost about 2.25 times as much for image output. Both renders reproduced “ASTRA 35” and “50 mm” legibly. One image per setting establishes a cost example; it gives limited evidence about visual quality on other prompts.
