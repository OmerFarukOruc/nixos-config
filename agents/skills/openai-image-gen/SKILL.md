---
name: openai-image-gen
description: Generates and edits images with OpenAI Images 2.6 through the Codex login or the OpenAI Images API. Supports reference images, transparent assets, and route-specific diagnostics.
disable-model-invocation: true
---
# OpenAI Images 2.6

Use the route the user selected for this request or batch. When the choice is open, ask before generation. Explain that the Codex login uses the ChatGPT subscription and the Images API bills the key’s API project, where eligible credits may apply. A key’s presence or a monthly credit amount does not establish a remaining balance. A failed request stays on the selected route unless the user chooses another.

## Choose settings with the user

Carry forward explicit settings. Derive aspect ratio and pixel dimensions from the destination when known. When a choice affects cropping, legibility, wait time, or API spend, offer a concrete recommendation with one useful alternative. Combine it with the route question where possible. For example, “For a slide draft I’d use Flare at low quality, 1536×864. For the small labels in the final, I’d use Sunburst at high quality at the same size. Which version and which account should I use?” A request that already specifies the account and suitable settings can proceed directly.

| Decision | How to choose |
| --- | --- |
| Model | Explain the trade-off for this image. Flare favors speed when exploring compositions. Sunburst favors detail and consistency when a label must stay legible or a product must keep its shape across edits. Both can generate, edit, and produce transparent backgrounds. On the API, select `gpt-image-2.6-flare` or `gpt-image-2.6-sunburst`. The Codex login cannot confirm either choice. |
| Quality | Choose from `auto`, `low`, `medium`, `high`, `xhigh`, and `max`. Suggest low for a sketch, medium for a general image, and high for fine lettering. Offer xhigh or max when additional detail matters enough to justify the time and cost. |
| Resolution | Offer square 1024×1024, portrait 1024×1536, landscape 1536×1024, or widescreen 1536×864 as the use suggests. For a 4K landscape deliverable, request 3840×2160. For custom still rasters, use multiples of 16, up to 3840 per edge, an aspect ratio within 3:1 either way, and 655,360–8,294,400 total pixels. GIFs have separate limits. |
| API complexity | Leave the default high for layouts with multiple elements. Low can suit a focused edit. Medium is also available. Increase quality for illegible text and adjust complexity for misplaced labels or objects. |
| Background and count | Request transparent PNG for cutouts and check the alpha channel. Use one image unless the user asks for variations. Agree on the count before spending credits on a batch. |

When a particular model, exact dimensions, or rendering quality matter, recommend the API. The Codex login has returned a different size or lower quality than requested. See the [OAuth measurements](references/api-behavior.md).

## Explain API cost before generation

When offering API credits or using them, quote an approximate USD output cost for the chosen model, quality, dimensions, and image count before sending. Include the per-image and batch estimates for multiple images. A user who already chose the route and settings needs the estimate without another approval question. For a Codex-only request, explain that it uses subscription allowance if the user asks about cost.

Consult the live [image generation guide](https://developers.openai.com/api/docs/guides/image-generation) for billing and format-specific controls. Use its [output cost calculator](https://developers.openai.com/api/docs/guides/image-generation#calculating-costs) with explicit settings. Consult the live [image prompting guide](https://developers.openai.com/api/docs/guides/image-prompting) when comparing models or advising on prompting, quality, or edit consistency. Use the GPT-Image-2.6 section of each guide. Reuse sources already checked during the request.

The calculator groups Flare and Sunburst. Use its shared estimate while it does so. Actual usage can differ. Complexity has no separate fee. Label the estimate as image output before any credits are applied; prompt tokens and reference-image inputs add to the total at the [current standard API rates](https://developers.openai.com/api/docs/pricing#image-generation). For `auto`, illustrate a named quality and size and say which choices remain open. Use format-specific billing guidance for GIF or SVG.

If the calculator is unavailable, this dated example gives the scale: on 2026-11-24 its standard API estimate for either model at one 1024×1024 still was about $0.025 at low, $0.043 at medium, $0.053 at high, $0.094 at xhigh, or $0.211 at max, before inputs. Label these as historical examples. For other dimensions, use the square example only to show scale and disclose that the requested size could not be priced. Proceed with an already authorized API request unless the user made a cost ceiling or an estimate a condition.

## Generate, inspect, and deliver

Set `SKILL_DIR` to the loaded skill directory. Label each reference by role and state which edit details must survive. For exact text, reference composition, iterative edits, or transparent edges, read [prompting tips](references/prompting-tips.md).

- **Codex login.** Follow [Codex login](references/codex-login.md) for generation, edits, preflight, PNG sidecars, and verification reports. For missing controls, unexpected dimensions, or maintenance, consult the dated [OAuth probe results](references/api-behavior.md).
- **API credits.** Follow [Images API](references/images-api.md) for the key, runnable generation and edit commands, or API-only output formats.

Inspect the saved image against the brief at its intended display size. Check exact text and layout, preserved details in edits, and cutout edges on a contrasting background. Deliver the file with its measured dimensions, the route used, the prompt, and any material mismatch. Distinguish requested settings from returned metadata. A retry that might add a charge needs to fit the agreed scope.

## Maintain

Compare upstream changes with the revisions in `agents/skills/SOURCES.md`. Compile changed helpers and run each with `--help`. Ask before live maintenance requests and agree on the route, settings, and count. For OAuth probes, use the commands in [OAuth probe results](references/api-behavior.md). Record only the controls each route actually demonstrated.
