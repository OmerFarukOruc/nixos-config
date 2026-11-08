---
name: openai-image-gen
description: Generates or edits raster images with OpenAI Images 2.6 (GPT Image 2.6 Sunburst and Flare) through the existing Codex ChatGPT login. Use for ChatGPT subscription image requests, reference-guided pictures, transparent assets, and Codex OAuth image diagnostics.
---
# Images 2.6 through Codex OAuth

Use `scripts/generate_image.py` with the existing Codex login in `~/.codex/auth.json`.
This skill uses logged-in Codex OAuth only. Use the Codex login for every request: an `OPENAI_API_KEY`, the upstream API-key CLI, and any other credential route stay out of it.
If this route fails, diagnose it and report the recovery through the same login.
Set `SKILL_DIR` to this skill's loaded directory.
User instructions take precedence over this skill.

## Choose the request

Complete authorized image requests through generation, inspection, and delivery.
Resolve routine composition choices from the prompt and conversation.
Ask only when missing information materially changes the result or needs new authority.
Skill maintenance authorizes reading and compiling the script; a live generation for a maintenance check needs the user's go.

Identify the asset's intended use, exact text, required details, and destination before building the prompt.
Treat a request to change an existing image while preserving its details as an edit.
Label supplied images by their role, such as edit target, style reference, or subject reference.
Use `--reference` (see Reference-guided generation) when the images guide a new picture, and `--style-reference` (see Edit) when one image is the edit target.

Images 2.6 has two models ([prompting guide](https://developers.openai.com/api/docs/guides/image-prompting), Overview):

| Model | Pick it for |
| --- | --- |
| `gpt-image-2.6-sunburst` | Demanding detail, layout, or edit accuracy; the script default |
| `gpt-image-2.6-flare` | Speed; the [release post](https://openai.com/index/introducing-images-2-6) reports as little as six seconds at `low` quality |

Use Sunburst with `max` quality and keep the original PNG for normal final-image work.
Use Flare when the user prioritizes speed, and a lower quality for drafts or reduced cost.
Quality sets visual detail, such as texture and small lettering; compare `medium` or `high` for small text, dense information, or several fonts.
The script defaults are Sunburst, `medium` quality, and `1536x1024`; pass every choice explicitly.
Request transparency with `--background transparent` and a prompt that names the isolated subject.

Choose dimensions that preserve the requested aspect ratio. Each edge is a multiple of 16 and at most 3840 pixels, the ratio stays within 3:1, and the area is 655,360 to 8,294,400 pixels. Sizes above `2560x1440` are experimental.
Maximum sizes by orientation: `3840x2160` (16:9), `2160x3840` (9:16), `2880x2880` (square).
Sources: [prompting guide](https://developers.openai.com/api/docs/guides/image-prompting), Model parameters; [image generation guide](https://developers.openai.com/api/docs/guides/image-generation) for the edge and area limits.
The script checks these limits before the request. A passing check does not show that the route honors the size: read Inspect and deliver.

## Route limits

Checked on 2026-11-08 (details and commands in [API behavior](references/api-behavior.md)):

- The route ignores the requested image model name and reports no model, so a model request stays unconfirmed in every report.
- `complexity` fails on every model with `invalid_value`, so the script has no flag for it.
- SVG and GIF output, markup edits, masks, and `input_fidelity` are Images API features the script does not send.
- `--size` is often replaced by `1536x1024`.

When a request needs one of these, say so and offer the nearest supported result, such as a PNG with `--background transparent` for an asset that would otherwise be SVG.

## Generate

Read [prompting tips](references/prompting-tips.md) for composition, exact text, preservation requirements, transparent assets, or expansion of a brief prompt.
Normalize detailed prompts while preserving their requirements; add only details that support a brief prompt's stated goal.
Choose unused output names, including numbered variations, PNG sidecars, and `<output>.json` reports.
Use the user's destination when supplied, or a descriptive path in the consuming project for project assets.
Run the generation command once; the script performs preflight automatically.
The script needs Pillow; when `python3 -c 'import PIL'` fails, run it through a Python that has it, on NixOS with `nix shell --impure --expr 'with import <nixpkgs> {}; python3.withPackages (p: [p.pillow])' -c python3 "$SKILL_DIR/scripts/generate_image.py" ...`.

```bash
python3 "$SKILL_DIR/scripts/generate_image.py" \
  --prompt "Draw a vintage typewriter on a wooden desk in soft window light." \
  --image-model gpt-image-2.6-sunburst \
  --quality max --size 3840x2160 --keep-png \
  --output ./typewriter.webp
```

The script requests PNG from the image tool and converts a copy to WebP at encoder quality 88.
The script adds no metadata of its own: the WebP carries none, and the PNG sidecar keeps whatever the response embedded.
The PNG sidecar preserves the original response bytes; WebP encoder quality is separate from rendering quality.
Use `--n` for independent variations; the script sends separate requests and numbers their output files.
Use a separate invocation and output name for each distinct asset or prompt.
Use `--prompt-file` for a long structured prompt.
Use `--help` for the complete CLI interface.

## Reference-guided generation

Pass `--reference PATH` once per image, for example three plates of a series, to make a new picture in their style or of their subject.
Each reference becomes one input image beside the prompt, and the tool action is `auto`.
References must be PNG, JPEG, WebP, or GIF files, and `--reference` cannot be combined with `--style-reference`.
Number each reference in the prompt, in the order of the `--reference` flags, and say what to take from it and what the new picture shows, because the prompt carries no style-preservation prefix in this mode.
The backend reports the action as `edit` and may return another size or quality than requested; the report then shows the mismatch and the script exits `5`.
Read [API behavior](references/api-behavior.md), Reference-guided generation, for the observed results.

## Edit

Inspect the reference image before selecting preservation requirements.
Use `--style-reference ./reference.png` for edits that preserve the reference's visual style.
This mode forces `action: edit` and adds palette, lighting, texture, and other style-preservation instructions.
It can conflict with requests to change those properties.
Report that limitation when the requested edit conflicts with the prefix.

For another style-preserving edit, pass the latest saved PNG as the new reference.
Restate required changes and details that must persist.
Each invocation is independent; the script does not retain conversation or response IDs.
`--style-reference` accepts one reference image, and the script sends no mask or markup.
Edit a region that must stay pixel-identical by compositing the approved edit into the original image, because prompting alone can still change preserved details ([prompting guide](https://developers.openai.com/api/docs/guides/image-prompting), Migrate an existing workflow).
Read [API behavior](references/api-behavior.md) when a request needs unsupported controls or the script needs maintenance.

## Inspect and deliver

Read the `<output>.json` report for requested settings, returned settings, actual image properties, and verification status.
Inspect each image against the requested subject, style, composition, exact text, and exclusions.
The report measures actual properties from the decoded response image before WebP conversion.
For `--background transparent`, the report adds `actual.transparent_pixels`; open the image on a contrasting backdrop, because a drawn checkerboard or a soft glow at the edges is not clean transparency.
Inspect identity, composition, and preserved details when the request includes an edit.
Deliver the original PNG for final-quality use and the WebP as a smaller preview.
For project assets, save selected finals in the consuming workspace and update the asset references required by the request.
Report saved paths, the final prompt, the Codex OAuth route, and any mismatch with the requested output.
When a visual requirement fails, make one targeted change and repeat inspection within the authorized request.
Report quality, size, and background as confirmed only when returned metadata matches the request; the model is never confirmed.
Missing or unrecognized metadata remains unverified.
The script saves images and reports before returning exit code `5` for mismatched or unverified settings.
When the size mismatches, deliver the image with the returned size named in the report, or rerun once with `--size 1536x1024` when the layout needs the honored size.
Treat exit code `5` as an unmet verification condition, not an authentication failure or instruction to regenerate.
Even verified rendering settings do not guarantee visual accuracy.
Public `max` quality and size limits are request targets, not proven private endpoint capabilities.

## Diagnose failures

Use standalone preflight only for an authorized OAuth diagnostic:

```bash
python3 "$SKILL_DIR/scripts/generate_image.py" --preflight --output /dev/null
```

Preflight can refresh an expired token and sends a small text request without an image tool.
It does not prove image-model access or generation readiness.
Keep tokens, account identifiers, headers, and raw response bodies out of reports.
Keep `auth.json` in its credential location.
Use `codex login` when the session cannot refresh.
Report failures through this OAuth route without switching credentials, endpoints, or requested quality.

If this skill blocks authorized work, link the exact instruction and explain the conflict.

## Maintain

After a change to request fields, response handling, reporting, or size validation, run `python3 -m py_compile "$SKILL_DIR/scripts/generate_image.py"`.
Then ask the user for one live generation that exercises the change, and read its `<output>.json` report.
Stop when that report shows the requested settings, unless new evidence leaves a required claim unresolved.
For upstream updates, read the diff from the revision recorded in nixos-config `agents/skills/SOURCES.md`.
Adapt prompt and workflow guidance to this CLI's supported controls, preserve the OAuth-only route, and advance the source revision after those checks pass.
Run the probes in [API behavior](references/api-behavior.md), Probes, again after a model release, because the route's limits can lift.
