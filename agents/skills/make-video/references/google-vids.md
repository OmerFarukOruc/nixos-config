# Google Vids in a browser the agent drives

Facts and recipes for building and changing a Vid (`docs.google.com/videos`) through the `agent-browser` skill, measured on 2026-11-24 in a 1920x992 browser window on a 16:9 Vid. The UI changes, so trust a snapshot over this file when they differ, and update this file.

Contents: Setup, Helpers, Scenes and clips, Text cards, Colours, Scene length, Transitions, Music, Export, Changing a finished Vid.

## Setup

Run the helpers in bash, sourcing them in the same shell call as the steps that use them:

```bash
bash -c 'VIDS_BROWSER="<browser command>" VIDS_SESSION=<session> VIDS_DIR=<scratch dir> source <skill dir>/scripts/vids.sh && <helper calls>'
```

- `VIDS_BROWSER` is the command of a browser signed in to the user's Google account, as the `agent-browser` skill's browser table names it (on a machine with a box browser, `box-browser`). The browser must save downloads and screenshots on the machine that runs the helpers.
- `VIDS_DOWNLOADS` is that browser's download folder, `~/Downloads` by default.
- `VIDS_DIR` is a scratch folder for this agent alone; its `snap.txt` is rewritten on every lookup.

Each helper returns non-zero when a lookup, click or key press fails. Chain steps with `&&` and stop on a failure: a key press sent after a failed lookup lands on the canvas, where it can type into a title or delete a scene (Ctrl+Z undoes both).

A new Vid: open `https://vids.new`, choose a blank video, then rename it with the title field.

## Helpers

| Helper | Does |
|---|---|
| `ref <regex>`, `clickr <regex>` | the ref of the last snapshot line that matches, or a click on it |
| `shot <name> [WxH+X+Y]` | a screenshot to `<scratch dir>/<name>.png`, cropped to the region when given; read the crop of the canvas or the timeline, because a full-window screenshot costs several times more to read |
| `canvasclick <x> <y>` | a mouse click at a screen point |
| `totaltime` | the film length the editor shows, such as `01:10.4` |
| `hook` | installs `scripts/upload-hook.js` in the page |
| `addclip <n> <file>` | adds scene `<n>`, which must be the new last scene, and uploads the clip into it |
| `newtext title\|subtitle\|body "<text>"` | inserts a text box and types the text; `\n` starts a new line |
| `style <size> <rrggbb> [font]` | font (default Nunito), size and colour of the selected box |
| `setcolor <button regex> <rrggbb>` | picks or adds a custom colour behind that button |
| `openfmt`, then `geom <w> <h> <x> <y>` | opens Format options and sets the selected box in pixels of the 1920x1080 canvas |
| `settrans <x> <y> <seconds>` | a dissolve at the transition marker at that screen point |
| `setsound <volume> <fade in> <fade out>` | the Sound panel of the selected audio |
| `replacetext <x> <y> "<text>"` | replaces the text of the box at that screen point, keeping its font, size and colour |
| `export_mp4 <destination>` | downloads the MP4 and moves the new file to the destination |

## Scenes and clips

- Uploads go through a hidden file input. Run `hook` once per page load; afterwards Insert > Upload exposes the input as `#vids-upload-input`, off screen, and `addclip` fills it.
- Insert > Upload puts the clip into the selected scene, which is why `addclip` creates and selects the new scene first.
- A clip fills its scene, and the scene takes the clip's length.

## Text cards

- Clicking "Insert text" while the Text panel is open closes it; run the step again.
- Text sits at the top of its box, so a box much taller than its text puts the text high. Size the box to the text, then measure the exported frame (stage 6) and move the box until the text block sits where you want it, within about 10 px.

## Colours

The hex field of the custom colour dialog ignores typed input. Type R, G and B into their own fields: R and G commit on Tab, B commits only on Enter, and that Enter also confirms the dialog. Ctrl+A does not select the B field, so `setcolor` clears it with End and four Backspaces. Once a colour exists, the palette lists it as "Custom Color #rrggbb", and `setcolor` clicks that swatch instead.

## Scene length

Scene length has no number field: drag the right edge of the scene in the timeline. A long drag can rescale the whole timeline, so that an 8.5 s card becomes 46 s; undo, zoom the timeline out, and drag in steps of a few pixels, reading `totaltime` after each. Expect the length to land 0.1 to 0.2 s off the target.

## Transitions

A transition overlaps the two scenes, so the film gets shorter by its length.

## Music

- Generate music: select scene 1, open "Generate music", choose Full, switch Instrumental on, type the prompt, Generate (1 to 3 minutes), then Insert.
- Insert places the song at the playhead. Click the very start of scene 1 so the playhead reads 00:00.0 before Insert.
- The Sound panel's volume control is not linear. Mean level of music-only scenes in one export: 20 % gave −52 dB, 50 % −40 dB, 80 % −28 dB, and 200 % clipped. Start at 80 % and measure the export (stage 6).
- The Sound panel also has automatic ducking; measure before relying on it.

## Export

`export_mp4` uses File > Download > MP4 video. A 70 s Vid arrived in 30 s to 7 minutes. The file is 1920x1080 H.264 30 fps with AAC audio, plus an automatic caption track (`mov_text`) whose speech recognition misspells names; `check-export.sh` writes a copy without it.

## Changing a finished Vid

- Change text with `replacetext`: it double-clicks into the box, selects all, deletes, then types. Typing over a Ctrl+A selection without the delete put the new text before the old.
- Another person viewing the Vid shows as a coloured frame and cursor on the canvas; neither it nor comments appear in the export.
