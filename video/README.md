# The walkthrough video

A narrated, captioned video (about 9 minutes) for the people who set the
challenge: what Secure GPU Stack is, how it differs from Lambda Stack, what
testing found, what was fixed, what isn't proven yet, and how the work was
done. Every number in it comes from `README.md` and `docs/`.

## What's in `out/`

- `secure-gpu-stack.mp4`: the video with its narration (HeyGen Voice Turbo,
  voice "noelle", through OpenRouter) and a quiet music bed. Captions are
  burned in.
- `secure-gpu-stack-no-voice.mp4`: the same video with only the music, to
  record your own voice over it.
- `narration-script.md`: every line with the time it starts, to read along.
- `captions.srt`: the captions as a separate file, for players and uploads
  that take one.

## How it's made

The video is an HTML page (`stage.html`) whose every animation is a function
of time. A headless browser renders it one frame at a time and ffmpeg encodes
the frames.

1. `script.js` holds the narration, scene by scene. Edit the words here.
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

Needs Node 22 or newer, ffmpeg (`brew install ffmpeg`), an OpenRouter key,
and Microsoft Edge or Google Chrome (set `BROWSER` to use another Chromium).
Run both scripts outside Claude Code's sandbox: one calls OpenRouter, the
other starts browsers that listen on local ports.
