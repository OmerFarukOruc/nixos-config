# Generated still images

How to make the master images, scene backgrounds, props and start frames a video needs.

## Generating

Read [`../../openai-image-gen/SKILL.md`](../../openai-image-gen/SKILL.md) and follow it for each OpenAI image: route, model, size, cost and the API call. Only the user can start that skill, so read the file instead of invoking it. Recommend its API route, because the video needs exact sizes, such as `1536x864` for 16:9, and one model for every image.

## Masters first

- Make one master image per character or style first, approve it at the look gate, and make every later image from the masters, not from the latest scene, so the look does not drift.
- For a subject that exists (a person, a known character, a pet), pass reference images of the real subject as inputs, saved in the project's `refs/` folder and listed in the plan. Its master is an image generated from those references in the video's style, or, when the video keeps the subject's real look, the clearest reference photo. Text alone gives a generic look of the same kind of subject; two reference images of the original gave a master that matched it.
- Describe a character by its look in prompts. A franchise or character name can point to different looks in different sources and can trigger a policy block, so names stay in labels and spoken lines. When a request is blocked for resemblance to an existing character, ask the user instead of rewording the same look.
- Use one plain, light background colour for masters and props, the same in every image; it keeps cut-outs and Character uploads clean.
- Make one image per request and look at it before the next.
- Keep each image's prompt, request settings, ordered inputs with roles, usage and verdict beside it in `images/`, and list approved files in `manifest.md`. Approved files are the source of truth; a prompt alone does not recreate them.

## Start frames

A start frame for a generated clip has a settled pose, the speaker's face unobstructed, room along the path of the movement, a quiet background, and no generated text. Where an approved pose already fits, composite the approved art into the scene with local tools instead of drawing it again.
