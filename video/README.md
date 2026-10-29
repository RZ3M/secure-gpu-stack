# The videos

Two narrated, captioned videos for the people who set the challenge. Every
number in them comes from `README.md` and `docs/`.

- **The walkthrough** (this folder, about 9 minutes, v0.1.0): what Secure GPU
  Stack is, how it differs from Lambda Stack, what testing found, what was
  fixed, what isn't proven yet, and how the work was done.
- **The M2 update** (`m2/`, about 3.5 minutes, v0.1.1): what changed since
  the walkthrough. The stack on an RTX 3080 in Ubuntu VMs, the five problems
  that found, Lambda Stack's install failing on the same machine, the head to
  head on the same GPU, and what's next (`docs/m2-test-bench.md`).

## What's in `out/`

For the walkthrough in `out/`, and the same set for the update in `m2/out/`
(named `secure-gpu-stack-m2-update…`):

- `secure-gpu-stack.mp4`: the video with its narration (HeyGen Voice Turbo,
  voice "noelle", through OpenRouter) and a quiet music bed. Captions are
  burned in.
- `secure-gpu-stack-no-voice.mp4`: the same video with only the music, to
  record your own voice over it.
- `narration-script.md`: every line with the time it starts, to read along.
- `captions.srt`: the captions as a separate file, for players and uploads
  that take one.

The MP4s are release assets, not tracked in git.

## How it's made

A video is an HTML page (`stage.html`) whose every animation is a function
of time. A headless browser renders it one frame at a time and ffmpeg encodes
the frames. `kit.css` and `kit.js` hold what both videos share: the frame
(background, chapter heading, captions, progress bar), the drawing toolkit,
and the engine that plays the scenes. Each `stage.html` adds its own scenes.

1. `script.js` holds the narration, scene by scene. Edit the words here. Its
   `name` sets the output files' names, and a line's `s` sets what the voice
   says when the caption would be misread.
2. `node video/build-audio.mjs` has OpenRouter's speech endpoint
   (`heygen/heygen-voice-1-turbo:free`, voice `noelle`) speak each line,
   works out the timing, and writes `build/timeline.js`, the narration track,
   the captions and the script. Only changed lines are requested again. The
   key comes from `OPENROUTER_API_KEY` or `.env`. `stage.html` times its
   animations to those lines, so a reworded line moves its visuals with it.
3. `node video/render.mjs --stills 12,40.5` renders single frames into
   `build/stills/` for checking. Opening `stage.html?t=40.5` in a browser
   shows the same frame.
4. `node video/render.mjs` renders the whole video into `out/` (about twelve
   minutes on an M2 Pro). After changing only the audio,
   `node video/render.mjs --mux-only` reuses the rendered frames.

For the update, give both scripts its folder: `node video/build-audio.mjs
video/m2`, then `node video/render.mjs video/m2` (with `--stills` or
`--mux-only` as above). Its `build/` and `out/` are inside `m2/`.

Needs Node 22 or newer, ffmpeg (`brew install ffmpeg`), an OpenRouter key,
and Microsoft Edge or Google Chrome (set `BROWSER` to use another Chromium).
Run both scripts outside Claude Code's sandbox: one calls OpenRouter, the
other starts browsers that listen on local ports.
