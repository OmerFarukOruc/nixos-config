---
name: make-video
description: "Makes a short video from parts (clips, still images, text cards, music, voice), from an interview and a written plan through generation, editing and checked export. Use when asked to make or produce a video, film, animated short, slideshow or montage, such as a gift or greeting video, or to change the text, music or scenes of a video made this way."
---

# Make a video

A video here is a timeline of parts: supplied or generated clips, still images, text cards, music and voice, assembled into one exported file. The run has seven stages. The plan file is the gate between talking and making: generation spends credits and money that do not come back, so nothing is generated, uploaded or edited until the user has read and approved the plan.

Keep every file of the video in one project folder, the folder the user names or a new folder named after the video, so another agent or machine can resume from the files alone. Reference images live there too; a path under `/tmp` on one machine is gone on the next. The layout:

| Path | Holds |
|---|---|
| `plan.md` | decisions, scenes, shot cards, tool facts and status (from the template) |
| `manifest.md` | every take and image: file, source, prompt file, settings, inputs with roles, cost, verdict, reason |
| `refs/` | reference images of real subjects |
| `images/`, `images/rejected/` | generated stills with their prompt and request files |
| `clips/`, `clips/rejected/` | clips as downloaded, named `<scene>_take<NN>_<res>.mp4` |
| `clips/final-cut/` | clips trimmed for the edit |
| `final/` | the delivered file |

Paths below that start with `scripts/`, `references/` or `assets/` are inside this skill's folder.

## 1. Interview

Interview the user before you make or change anything; reading what the user points at is fine. Ask one question at a time, give your recommended answer with its reason, and wait for the reply (the `grilling` skill's style). When a file, a link the user gave, or a check you can run answers a question, use it instead of asking.

Cover each branch:

- **Purpose**: who it is for, what the viewer should feel, private or published, and where it may be uploaded.
- **Shape**: length, aspect ratio, resolution, deadline. The Google Vids steps in this skill were measured on a 16:9 Vid; for another ratio, prove it in the pilot or assemble with ffmpeg.
- **Story**: the scenes in order, and the ideas the user already has. Offer 2 or 3 concepts when the user has none.
- **Parts**: for each scene, its source: supplied footage or photos, a generated clip, a generated still, or a text card.
- **Real subjects**: every person, existing character, pet, place or object that must look like the real one. Ask for reference images of each, or permission to search and download them. A look described in text alone comes out generic.
- **Language**: of speech and of on-screen text, and any style guide or skill the user wants for that language.
- **Voice**: who says which line, and the voice source (generated inside the clip, a voiceover, or a recording).
- **Music**: generated, supplied or none, and its mood.
- **Tools and spending**: the generators and editor (for example Google Flow, Google Vids, an image API, or local ffmpeg), the account's plan and credit balance, and the spending limit. You drive signed-in web tools yourself through the `agent-browser` skill, and the user approves; only without a browser you can drive does the user click, from the shot cards, while you check each file that comes back.
- **Gates**: the points where the user wants to approve. Recommend four: the plan, the look (the master images, approved before any clip is generated), the pilot (stage 3), and the final file.
- **Authorship**: who writes the creative drafts (the story, lines, prompts and card texts): you, another model the user names, or the user.
- **Delivery**: the final file name and folder, and whether the editor project must stay editable for later changes.

Done when every branch has an answer or the user's "you decide", and you have read back the decisions in one message.

## 2. Plan

Read the reference for each tool the plan uses (listed in stages 4 and 5), then write `plan.md` in the project folder from [`assets/plan-template.md`](assets/plan-template.md). The template's headings bind; write "none" under a heading that does not apply. Give the user the file path and ask for approval.

Done when `plan.md` exists with every heading filled and the user's approval is recorded in its Decisions table with the date. The first generation, upload or edit comes after that line.

## 3. Pilot

Before you make every part, prove each step of the pipeline once, end to end, on the smallest real piece:

- one clip from each route the plan uses (for example one silent clip and one speaking clip);
- one text card with its real text, including every special letter of the language (for Turkish `ğ ı İ ş ç ö ü`);
- the music at its planned level, when the plan has music;
- one export from the real editor, checked with `scripts/check-export.sh` (stage 6).

Docs and earlier notes about a tool are claims until the pilot shows them. Flow's help lists a free 1080p upscale for clips up to 10 s, yet a 360p Omni clip offered only a 720p upscale (2026-11-24). Vids music at 20 % measured −52 dB in the music-only parts, which is silence on a phone, so a pilot checks levels with the script, not by ear. Write each fact the pilot measures into the plan's Tool facts table with the date.

Done when the pilot export passes `check-export.sh` and, when the pilot is a gate, the user has approved it.

## 4. Make the parts

- Make one part per request and look at it before you make the next. Record each take and image in `manifest.md`.
- Before each paid generation, read back from the page the settings and the attached inputs, and compare them with the plan's shot card. Flow keeps the last start frame and ingredients selected for the next generation, and its defaults (720p, 2 outputs) cost six times as much as 360p with 1 output.
- Make new scenes from the approved master images, never from the latest scene, so the look does not drift.
- Tool notes: [`references/google-flow.md`](references/google-flow.md) for Flow clips, [`references/images.md`](references/images.md) for generated stills.

Done when every part in the plan has an accepted take in `manifest.md`, and the look gate, when the plan lists it, is approved.

## 5. Assemble

- Trim clips to the plan's ranges locally with ffmpeg (`nix shell nixpkgs#ffmpeg` when it is missing) before you upload them; the editor then only places them. For a clip with speech, find where the speech starts and ends with `silencedetect`, and keep at least 0.3 s of the clip before the first word and after the last, so no syllable is lost.
- In Google Vids, follow [`references/google-vids.md`](references/google-vids.md); its helpers are in `scripts/vids.sh`.
- Set the music level by measurement, not by the editor's percent control: music-only parts at a mean of about −28 to −30 dB, speech parts at least 6 dB above the average of the music-only parts.
- When the editor blocks a step twice after a fresh look at the cause, the fallback is the same timeline assembled with ffmpeg alone. When the plan requires an editable project, ask the user before you switch; otherwise switch and say so in the report.

Done when the editor's timeline matches the plan's Scenes table: order, lengths, transitions and music.

## 6. Export and check

Export, then run `scripts/check-export.sh <downloaded file> <scratch folder> <segments file>`; `--help` prints the segments format, one line per scene with its time range and kind from the plan's Scenes table. The script writes a copy without subtitle and caption tracks, because a Vids MP4 carries automatic captions that misspell names, and prints the streams, the level of each segment, silences, loudness and true peak, then writes a frame sheet and one full frame per card.

Look at every frame image it writes. A check fails when the script prints a FAIL line, when the format or length differs from the plan, or when a frame shows a scene missing, out of order, or a wrong letter on a card. On a failure, fix it in the editor, export again and rerun the script. Keep the previous deliverable until the new file passes.

Done when the clean copy passes every check, sits at the delivery path from the plan, and, when the plan lists the final-file gate, the user has approved it.

## 7. Report

Update `plan.md` (Status, Tool facts, any departure from the plan with its reason) and write a short report beside it: the file path, the editor project link, the checks with their numbers, the departures, and what the user could still check, such as watching it on a phone. Close every browser tab you opened. Share or publish the video only when the plan says so and the final-file gate, when listed, is approved.

A later change, such as new card text or another music level, reopens the same editor project when one exists: make the change, export, rerun stage 6, then replace the file and update the report.
