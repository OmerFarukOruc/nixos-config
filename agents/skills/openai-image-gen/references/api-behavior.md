# API behavior

Checked on 2026-11-08 against the public pages and the local scripts; Reference-guided generation was checked on 2026-10-28.

Contents: Request structure, Controls outside the CLI, Probes, Reference-guided generation, Failure limitations, Verification report, Sources.

## Request structure

The script uses the private `https://chatgpt.com/backend-api/codex/responses` endpoint with Codex OAuth.
Public Responses documentation defines the analogous request fields, not this route's authentication or account access.

| Concern | Current script behavior |
| --- | --- |
| Orchestration | Top-level `model: gpt-6-astra`, no `reasoning` field |
| Image model | `gpt-image-2.6-sunburst` or `gpt-image-2.6-flare` inside `tools[]`; the route ignores it (see Probes) |
| Action | `generate`, `auto` with `--reference`, or `edit` with `--style-reference`; forced image tool choice |
| Image controls | Tool-level `size`, `quality`, `output_format: png`, and `background` when `--background` is set |
| Image input | One data URL per `--reference`, or one for `--style-reference` |
| Response | SSE; extracts base64 from completed `image_generation_call` output |
| Storage | `store: false`; no response-ID continuation |
| Variations | Independent requests; no tool-level `n` |
| Local output | WebP conversion without metadata; optional unchanged PNG sidecar; JSON verification report |

The script sends no `reasoning` field because the route turns `reasoning.effort` into a `complexity` value that every image model rejects (see Probes).
The [prompting guide](https://developers.openai.com/api/docs/guides/image-prompting), Model parameters, also says GPT Image 2.6 does not support `reasoning.summary` and asks to omit `input_fidelity` on edits.
The [Astra guide](https://developers.openai.com/api/docs/guides/latest-model) requires Responses for tool use and excludes `none` reasoning.

## Controls outside the CLI

The 2.6 models take `complexity` (`low`, `medium`, `high`; omitted means `high`), `markup` on edits, `output_format` `svg` and `gif` (with `frame_count` and `frame_duration_ms`), and `output_compression` for JPEG and WebP.
The prompting guide and the [image generation guide](https://developers.openai.com/api/docs/guides/image-generation) place SVG, GIF, and markup on `POST /v1/images/generations` and `POST /v1/images/edits`, the Images API, which needs an API key.
Public Responses supports continuation through previous response IDs or image outputs supplied in context.
The script implements neither form of stored conversation continuation.
Reusing a saved image supplies visual context only.
The script exposes no mask, markup, or partial image events and buffers the stream until it finishes.
It discards response IDs, revised prompts, and usage.
It retains allowlisted quality, size, format, background, and action fields in `<output>.json`.
Unsupported or missing field values become unverified; arbitrary response content is excluded.

The Images API has different request placement: the image model is top-level and generation accepts `n`.
Do not copy those fields into a Responses image tool request.
Public API examples do not authorize an endpoint or credential change.

## Probes

Run each probe with `python3 "$SKILL_DIR/scripts/probe_route.py" '<tool json>' ['<request overrides json>']`; it sends one request, saves no image, and prints the route's answer. Each probe sends a billable image request, so run it only for a maintenance check the user authorized.
Results on 2026-11-08, with the argument that produced each:

| Argument | Answer |
| --- | --- |
| `'{"model":"gpt-image-2.6-flare","quality":"low"}'` | Image returned; the item has no `model` field |
| `'{"model":"gpt-image-2.6-bogus","quality":"low"}'` | Image returned; the route accepts an unknown model name |
| `'{"quality":"low","complexity":"low"}'` (also `medium`, `high`, with `gpt-image-2.6-sunburst`, `gpt-image-2.6-flare`, and `gpt-image-2.5-flare`) | `invalid_value`: "Complexity 'low' is not supported for this image model." |
| `'{"model":"gpt-image-2.6-flare","quality":"low"}' '{"reasoning":{"effort":"low"}}'` (also `medium`, `high`) | The same error, naming the effort as the complexity |
| `'{"model":"gpt-image-2.6-flare","quality":"low","output_format":"gif"}'` | HTTP 400: "GIF output is not enabled for the model 'gpt-image-2-codex'." |
| `'{"model":"gpt-image-2.6-flare","quality":"low","output_format":"svg"}'` | HTTP 400: "SVG output is not supported for this model." |
| `'{"model":"gpt-image-2.6-flare","quality":"low","output_format":"webp"}'` | Image returned with `output_format: webp` |
| `'{"model":"gpt-image-2.6-sunburst","quality":"medium","background":"transparent"}'` | Item reports `background: transparent`; the decoded PNG has transparent pixels |

The GIF error names `gpt-image-2-codex` as the model behind the route, whatever the request names.
No response names an image model, so the script reports `requested_model` and never confirms it.
Whether the route renders with the Images 2.6 weights is not confirmed.

Requested sizes on the same day, quality `low`:

| Requested | Returned |
| --- | --- |
| `1536x1024` | `1536x1024` |
| `1024x1024` (3 runs) | `1536x1024` |
| `1024x1536` | `1536x1024` |

Earlier runs returned other sizes, such as `1374x1145` and `1557x1010`, and `max` requests came back as `high` or `medium`.
Read each response's report instead of assuming a setting was honored.

## Reference-guided generation

The [image tool guide](https://developers.openai.com/api/docs/guides/tools-image-generation) lets one request carry several `input_image` items with `action: auto`, and the model then decides whether to generate or edit.
On 2026-10-28 three live requests sent three landscape engraved plates of about 3:2 each:

| Requested | Returned |
| --- | --- |
| `1024x1024`, `low` | `action: edit`, `low`, `1536x1024` |
| `1536x1024`, `low` | `action: edit`, `medium`, `1557x1010` |
| `1536x1024`, `low` | `action: edit`, `medium`, `1536x1024` |

All three images matched the plates' style.
On 2026-11-08 a `--reference` run with two images and a `--style-reference` run at `1536x1024`, `low` both returned the requested size and quality (status `verified`); the first reported the action as `edit`.
The returned size need not be a multiple of 16; read `actual.size` and `returned.quality` in the report.

## Failure limitations

Preflight treats HTTP 429 as a passed connectivity check.
That status does not prove authentication or generation readiness.
A 200 preflight checks HTTP status without inspecting the completed text response.

The SSE parser rejects failed, incomplete, and error events without printing server messages.
`probe_route.py` prints them, because the error text names the rejected field.
A stream without a completed response also fails.

## Verification report

Each output has a `<output>.json` sidecar with `requested`, `returned`, `actual`, `status`, `mismatches`, `unverified`, and `requested_model`.
The report lists mismatched comparisons and unverified fields separately.
Actual size and format come from the decoded response image, before local WebP conversion.
With `--background transparent`, `actual.transparent_pixels` is true when the decoded image has a pixel below full alpha, and a false value is a mismatch.
Concrete returned values satisfy `auto` requests; unspecified returned values cannot prove a concrete setting.

For generation and edits, exit code `0` means all requested settings were verified for every image.
Exit code `5` means images were saved but some settings mismatched or remained unverified.
Images and reports remain available for inspection after exit code `5`.
This status does not trigger a retry or a lower-quality request.
The script refuses existing output and sidecar paths.

## Sources

- [Image prompting guide](https://developers.openai.com/api/docs/guides/image-prompting): GPT Image 2.6 models, parameters, prompting fundamentals, and edit patterns.
- [Introducing Images 2.6](https://openai.com/index/introducing-images-2-6): Flare and Sunburst positioning, complexity, availability.
- [Image generation guide](https://developers.openai.com/api/docs/guides/image-generation): size limits, complexity, SVG and GIF fields.
- [Image tool guide](https://developers.openai.com/api/docs/guides/tools-image-generation): actions, prompt revision, continuation, and streaming.
- [Responses reference](https://developers.openai.com/api/reference/resources/responses/methods/create#responses-create-tools): tool fields and response structure.
- [Images reference](https://developers.openai.com/api/reference/resources/images): separate image endpoints and their parameters.
