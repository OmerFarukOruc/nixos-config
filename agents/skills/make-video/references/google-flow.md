# Google Flow clips

Facts about making clips in Google Flow (`flow.google.com`) through the `agent-browser` skill, measured on a Google AI Pro account on 2026-11-24 with the Omni Flash 1.2 model. Prices and limits change; confirm them on the page and record them in the plan's Tool facts table.

## Before the first upload

- Turn off "Help improve Google Flow" in the account settings, so uploads and outputs are not used to train models. Check the visible watermark setting too.
- The image upload accepts `.png .jpg .jpeg .webp .gif .heif .heic` (the file input's `accept` list).

## Settings that cost

- The defaults are 720p with 2 outputs (48 credits for 8 s). Set 360p and 1 output (1 credit per second) for every draft, and read both back before each Generate.
- The download menu of a 360p clip offers "720p Upscaled" for 0 credits, not 1080p. A Vids export of 720p clips is 1920x1080.
- Seconds 11 to 15 of a clip cost double; keep each clip at 10 s or less.

## Characters and routes

- A Character holds 1 or 2 images and a voice and is called with `@Name` in the prompt. Creating one costs 0 credits, and its portrait keeps the uploaded master image.
- Speech needs the Ingredients route with the Characters attached. The Frames route (start and end frame) has no slot for a Character, so it has no character voice; use it for silent shots whose composition matters.
- A speaking clip longer than its line lets the silent Character speak in the leftover seconds. Keep a speaking clip about 6 s for a line of 11 to 14 syllables, and write that the listener "stays completely silent throughout the entire clip without saying a single word".
- Flow keeps the last selected start frame and ingredients for the next generation. Before each Generate, read the attached inputs from a snapshot and compare them with the shot card.

## Uploads and downloads

- The upload button opens a hidden file input. Install the hook first with `<browser command> --session <session> eval --stdin < <skill dir>/scripts/upload-hook.js`; it exposes the input as `#vids-upload-input`, and `<browser command> --session <session> upload "#vids-upload-input" <file>` fills it.
- Download through the clip's More options > Download menu; the file lands in the browser's download folder with a generated name. Move it to `clips/<scene>_take<NN>_<res>.mp4` at once. agent-browser's `download` command fails when the browser is attached over CDP, as a box browser is; click the menu item instead.
