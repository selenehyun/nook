---
name: update-macos-screenshot
description: Recapture the running Nook macOS app window (window-only, with drop shadow) and replace the README hero screenshot at docs/screenshots/main.png. Use when asked to update, refresh, or replace the macOS app screenshot.
---

# Update the macOS screenshot

Replaces `docs/screenshots/main.png` (the README hero) with a fresh window-only
capture of the running Nook Mac app — drop shadow and rounded corners on a
transparent background, matching the existing style.

## Prerequisites

- **Nook is running** and showing the state you want in the shot. A good hero
  has an **article open in the reader** (not the "Select an Article" empty
  state) and the sidebar + article list populated. Ask the user to pick an
  article if the reader looks empty.
- The terminal running these commands needs macOS **Screen Recording**
  permission; if the capture comes out empty/black, that's the cause.

## Steps

1. From the repo root, run the capture script (writes the hero path by default):

   ```sh
   .claude/skills/update-macos-screenshot/capture.sh
   ```

   It finds Nook's largest window via `winid.swift`, activates the app, and runs
   `screencapture -l<id>` (which keeps the shadow — do **not** add `-o`, which
   removes it).

2. **Verify the result** by viewing `docs/screenshots/main.png` (Read tool). Confirm
   it's the real window with content (not black/empty, reader not on "Select an
   Article"). If it's wrong, fix the app's state and re-run.

   - To preview without overwriting the committed file, pass a temp path:
     `.claude/skills/update-macos-screenshot/capture.sh /tmp/nook-window.png`,
     view it, then re-run without an argument once it looks right.

3. Commit just the screenshot:

   ```sh
   git add docs/screenshots/main.png
   git commit -m "docs: refresh the macOS screenshot"
   ```

   (Follow the repo's commit conventions / co-author trailers.)

## Notes

- Aspect ratio depends on the app window's size; the README scales the image to
  `width="900"`, so exact pixels don't matter, but keep the window a reasonable
  reading size before capturing.
- `winid.swift` matches the window whose owner is `Nook`, on the normal window
  layer, with the largest area — so panels/sheets don't get picked instead.
