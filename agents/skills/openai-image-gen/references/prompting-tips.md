# Image prompting tips

Use this reference for composition, exact text, preservation requirements, transparent assets, or expansion of a brief prompt.
It follows the [GPT Image 2.6 prompting guide](https://developers.openai.com/api/docs/guides/image-prompting), limited to the controls this CLI sends.

Contents: Structure, Specificity, Generation, Text, Editing, Transparent assets, Iteration, Check the result, Examples.

## Structure

Start with an explicit action such as `draw` or `edit` and include the intended use.
For complex prompts, organize the request as scene, subject, details, and constraints, using only the labeled lines that help:

```text
Asset: <where the image will be used>
Request: <the user's requested generation or edit>
Input image: <number and role of each: edit target, style reference, subject reference>
Scene: <background and setting>
Subject: <main subject and action>
Style: <photo, illustration, or other medium>
Composition: <framing, viewpoint, placement, and space for copy>
Lighting: <light direction and mood>
Materials: <textures and colors that matter>
Text: "<verbatim text>"; <typography, placement, and how many times it appears>
Preserve: <details that must remain unchanged>
Exclude: <unwanted elements specified by the request>
```

These labels structure the prompt; they are not CLI flags. Short prompts, paragraphs, and JSON-like structures all work, so choose the format that is easiest to read and update.
Rendering quality, dimensions, and background belong in the CLI options described in SKILL.md.

## Specificity

Normalize a detailed prompt without adding creative requirements.
For a brief prompt, add framing, practical layout, or concrete scene details only when they support the stated goal.
Keep characters, props, branding, slogans, palettes, and story details grounded in the request.
Use concrete materials, shapes, textures, and colors instead of repeated quality adjectives.
Place room for copy where the consuming layout needs it; derive left/right placement from that layout.
For wide, cinematic, low-light, rainy, or neon scenes, give scale, atmosphere, and color instead of mood words alone.

## Generation

- State `photorealistic` or `real photograph` when a photographic result is required; camera specifications cue the look and do not simulate a camera.
- Specify close-up, wide, top-down, eye-level, or low-angle framing, and soft, diffuse, golden-hour, or high-contrast lighting.
- For people, name body framing, relative scale, gaze, and interaction, such as `full body visible, feet included` or `hands naturally gripping the handlebars`.
- Name the place and date for a historical scene, then inspect clothing, staging, and surroundings for accuracy.
- Describe an interface preview as a shipped product: layout, hierarchy, spacing, and real elements, without concept-art words.
- For a diagram, slide, or chart, name the deliverable and audience and give the real labels, numbers, and footnotes; use a landscape size for slides and `medium` or `high` quality for small text. Check every figure the model adds.
- For a comic, write one concrete visual beat per panel.
- For a character that must recur, fix its appearance, proportions, and outfit in one reference image, then repeat those details in each later prompt.

## Text

Quote exact text and specify font style, size, color, and placement when those details matter.
State how many times the text appears and ask for no extra text.
Spell uncommon words and brand names letter by letter when that helps accuracy.
Check every visible word after generation; correct spelling in the prompt does not prove correct rendering.

## Editing

State what must change and what must remain unchanged.

Use explicit constraints such as `change only the mug color; preserve its shape, handle, label, background, and shadows`.
For identity-sensitive edits, name the face, body, pose, hair, and expression that must persist.
For text replacement or translation, name the layout, typography, spacing, and surrounding imagery that must persist.
For object removal, name the object and say `do not change anything else`.
For a sketch-to-render edit, say to preserve layout, proportions, and perspective and to add no new elements or text.
For insertion into a scene, state the lighting, body framing, gaze, and interaction.

`--style-reference` accepts one reference image.
Its style prefix preserves palette, lighting, surfaces, depth of field, grain, and color grading.
Check that those constraints match the requested edit.
`--reference` accepts several images and adds no style prefix, so the prompt names each reference by its number (image 1 is the first `--reference`), says what to take from it, how the inputs combine, and what the new picture shows.

Repeat critical preservation requirements during later edit iterations.
Prompting cannot supply masks or markup; the script sends neither.
A region that must stay pixel-identical comes from compositing the approved edit into the original.

## Transparent assets

Pass `--background transparent` and ask for the isolated subject in the prompt: centered, crisp silhouette, no halos or fringing, and no solid backdrop, checkerboard, scenery, shadow, or watermark.
Repeat the transparency requirement in later edits.
Read `actual.transparent_pixels` in the report, then check the edges on a contrasting backdrop.

## Iteration

Start with a complete prompt.
Make one intentional change in each later iteration, passing the previous output as the next reference.
Restate any detail that must not drift, because `same style as before` can lose critical constraints.
Compare results before adding more instructions.

## Check the result

Can every word be read, and does it match the requested text?
Are diagram labels and relationships correct?
Do identities, product shapes, labels, and reference details remain intact?
For a transparent asset, does the decoded file contain transparent pixels?

## Examples

For a brief request to make a coffee mug image for a website hero:

```text
Draw a ceramic coffee mug for a website hero.
Style: clean product photography.
Lighting: soft studio light.
Composition: wide framing; leave room for copy where the page layout requires it.
```

For a request to recolor a mug while preserving its photograph:

```text
Edit the reference photo. Change only the mug's glaze to blue.
Preserve: mug shape, handle, label text, camera angle, background, light direction, and shadows.
```

For a transparent logo (with `--background transparent`):

```text
Create an original logo for a local bakery called Field & Flour.
Warm, simple, timeless; clean vector-like shapes, strong silhouette, balanced negative space, flat, no gradients.
Single centered logo with generous padding, clean alpha edges, no solid backdrop, scenery, checkerboard, or watermark.
```

Adapt examples to the request; their scene and layout details are not default requirements.
