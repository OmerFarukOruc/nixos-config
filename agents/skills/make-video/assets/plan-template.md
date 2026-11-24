# Plan: <video title>

Project folder: `<path>`. This file and `manifest.md` hold the state of the video; update Status after each stage.

## Decisions

One row per interview branch, with the user's answer or "you decide" and what you chose. Story, Parts and Real subjects have their own sections below.

| Branch | Decision |
|---|---|
| Purpose: audience, feeling, private or published, where it may be uploaded | |
| Shape: length, aspect ratio, resolution, deadline | |
| Language of speech and text, and its style guide | |
| Voice: who says which line, voice source | |
| Music: source and mood | |
| Tools and spending: generators, editor, account plan, balance at start, limit | |
| Browser steps | the agent drives signed-in tools through the agent-browser skill; the user approves |
| Gates | |
| Authorship of the creative drafts | |
| Delivery: final file name and folder | |
| Editable project required | yes or no |
| Plan approved | date, and the user's words |

## Story

The concept in two or three sentences.

## Scenes

| Scene | Content | Source | Route or tool | Kept range (s) | Length in edit (s) | Kind | Join to next |
|---|---|---|---|---|---|---|---|
| T0 | title card: exact text | card | editor text | | | card | |

Source is one of: supplied, generated clip, generated still, card. Kind decides the scene's sound and is the kind `scripts/check-export.sh` checks:

| Kind | Sound in the edit |
|---|---|
| card | a text card under music |
| music | music only: a muted clip or a still |
| speech | the clip's own sound, with speech, kept under the music |
| clip | the clip's own sound, without speech, kept under the music |

Length of the film = the sum of the edit lengths minus the transition overlaps.

## Shot cards

One card per generated part, here or in `shots/<scene>.md`: the exact prompt, the inputs with their roles, the settings to read back before generating (model, resolution, duration, number of outputs, cost), the spoken line quoted unchanged, the speaker and the silent listener, and the take name to save.

## References and looks

Each real subject and its reference images in `refs/`, with their source. The approved master image of each character or style, once it exists.

## Text cards

Each card's exact text, line breaks included, its font, size and colours.

## Music and voice

Music source, prompt and mood, and planned level: music-only parts about −28 to −30 dB mean, speech at least 6 dB above the average of the music-only parts. Voice source for each line.

## Pilot

The pieces the pilot makes and the check that passes each.

## Costs

Cost per part, the expected total, and the limit.

## Tool facts

| Fact | Measured value | Date | How measured |
|---|---|---|---|

## Status

| Stage | State | Evidence |
|---|---|---|
| 1 Interview | done | |
| 2 Plan | waiting for approval | |
| 3 Pilot | not started | |
| 4 Parts | not started | |
| 5 Assemble | not started | |
| 6 Export and check | not started | |
| 7 Report | not started | |
