// Turns script.js into the narration track, the timeline the visuals follow,
// and captions:
//   build/audio/*.wav     one clip per line, from OpenRouter's speech endpoint
//   build/timeline.js     scene and line timings, loaded by stage.html
//   build/narration.wav   voice + music bed, ducked under the voice
//   build/music.wav       the music bed alone (for a version without the voice)
//   out/captions.srt, out/narration-script.md
//
// Usage: node video/build-audio.mjs
// The OpenRouter key comes from OPENROUTER_API_KEY or the project's .env.
// Clips are cached: only lines whose text, model or voice changed are
// requested again.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const BUILD = path.join(HERE, 'build');
const AUD = path.join(BUILD, 'audio');
const OUT = path.join(HERE, 'out');
fs.mkdirSync(AUD, { recursive: true });
fs.mkdirSync(OUT, { recursive: true });

await import(pathToFileURL(path.join(HERE, 'script.js')).href);
const { model, voice, fps, scenes } = globalThis.SCRIPT;
const SR = 44100;

// How the voice should say words it would otherwise spell out or misread.
const SAY = [
  [/sgs-check/g, 'S G S check'],
  [/krabs's/g, "crabs's"],
  [/krabs/g, 'crabs'],
  [/cuDNN/g, 'coo D N N'],
  [/NCCL/g, 'nickel'],
  [/\bJAX\b/g, 'jacks'],
  [/JupyterLab/g, 'Jupiter Lab'],
  [/Jupyter/g, 'Jupiter'],
  [/NVIDIA's/g, "Nvidia's"],
  [/NVIDIA/g, 'Nvidia'],
  [/NVSwitch/g, 'N V switch'],
  [/io_uring/g, 'I O U-ring'],
  [/aa-exec/g, 'A A exec'],
  [/\bGLM\b/g, 'G L M'],
  [/DeepSeek/g, 'Deep Seek'],
  [/GTX 1070/g, 'G T X ten seventy'],
  [/\bSBOM\b/g, 'S-bom'],
  [/systemd's/g, "system D's"],
  [/R580/g, 'R 580'],
  [/Ubuntu 24\.04/g, 'Ubuntu 24 oh 4'],
  [/cloud-init/g, 'cloud init'],
  [/\b1001\b/g, 'ten oh one'],
  [/localhost/g, 'local host'],
  [/\bPASS\b/g, 'pass'],
];
const speak = (text) => SAY.reduce((s, [re, r]) => s.replace(re, r), text);

function readWav(file) {
  const b = fs.readFileSync(file);
  let off = 12;
  let fmt = null;
  while (off + 8 <= b.length) {
    const id = b.toString('ascii', off, off + 4);
    const size = b.readUInt32LE(off + 4);
    if (id === 'fmt ') fmt = { ch: b.readUInt16LE(off + 10), sr: b.readUInt32LE(off + 12), bits: b.readUInt16LE(off + 22) };
    if (id === 'data') {
      if (!fmt || fmt.ch !== 1 || fmt.sr !== SR || fmt.bits !== 16) throw new Error(`${file}: unexpected format ${JSON.stringify(fmt)}`);
      const pcm = new Int16Array(b.buffer.slice(b.byteOffset + off + 8, b.byteOffset + off + 8 + size));
      return Float32Array.from(pcm, (v) => v / 32768);
    }
    off += 8 + size + (size % 2);
  }
  throw new Error(`${file}: no data chunk`);
}

function writeWav(file, channels) {
  const n = channels[0].length;
  const ch = channels.length;
  const b = Buffer.alloc(44 + n * ch * 2);
  b.write('RIFF', 0); b.writeUInt32LE(36 + n * ch * 2, 4); b.write('WAVE', 8);
  b.write('fmt ', 12); b.writeUInt32LE(16, 16); b.writeUInt16LE(1, 20); b.writeUInt16LE(ch, 22);
  b.writeUInt32LE(SR, 24); b.writeUInt32LE(SR * ch * 2, 28); b.writeUInt16LE(ch * 2, 32); b.writeUInt16LE(16, 34);
  b.write('data', 36); b.writeUInt32LE(n * ch * 2, 40);
  let o = 44;
  for (let i = 0; i < n; i++) {
    for (let c = 0; c < ch; c++) {
      const v = Math.max(-1, Math.min(1, channels[c][i]));
      b.writeInt16LE(Math.round(v * 32767), o); o += 2;
    }
  }
  fs.writeFileSync(file, b);
}

// Trim the silence around a clip, keeping a few milliseconds.
function trim(x) {
  const th = 0.004;
  let a = 0; while (a < x.length && Math.abs(x[a]) < th) a++;
  let z = x.length - 1; while (z > a && Math.abs(x[z]) < th) z--;
  const pad = Math.round(0.03 * SR);
  return x.subarray(Math.max(0, a - pad), Math.min(x.length, z + pad));
}

function apiKey() {
  if (process.env.OPENROUTER_API_KEY) return process.env.OPENROUTER_API_KEY;
  const env = path.join(HERE, '..', '.env');
  const m = fs.existsSync(env) && fs.readFileSync(env, 'utf8').match(/^OPENROUTER_API_KEY=["']?([^"'\s]+)/m);
  if (!m) throw new Error('Set OPENROUTER_API_KEY, or put it in .env');
  return m[1];
}

// One line of speech, saved as a 16-bit mono WAV. The endpoint returns raw
// 16-bit PCM and names its rate in Content-Type ("audio/pcm;rate=44100;channels=1").
async function speech(text, file, key) {
  for (let attempt = 1; ; attempt++) {
    const r = await fetch('https://openrouter.ai/api/v1/audio/speech', {
      method: 'POST',
      headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ model, input: text, voice, response_format: 'pcm' }),
    });
    if (r.ok) {
      const type = r.headers.get('content-type') || '';
      const rate = +(type.match(/rate=(\d+)/) || [])[1];
      const chans = +(type.match(/channels=(\d+)/) || [0, 1])[1];
      if (!type.startsWith('audio/pcm') || rate !== SR || chans !== 1) throw new Error(`unexpected audio: ${type}`);
      const pcm = Buffer.from(await r.arrayBuffer());
      const head = Buffer.alloc(44);
      head.write('RIFF', 0); head.writeUInt32LE(36 + pcm.length, 4); head.write('WAVE', 8);
      head.write('fmt ', 12); head.writeUInt32LE(16, 16); head.writeUInt16LE(1, 20); head.writeUInt16LE(1, 22);
      head.writeUInt32LE(SR, 24); head.writeUInt32LE(SR * 2, 28); head.writeUInt16LE(2, 32); head.writeUInt16LE(16, 34);
      head.write('data', 36); head.writeUInt32LE(pcm.length, 40);
      fs.writeFileSync(file, Buffer.concat([head, pcm]));
      return;
    }
    const body = (await r.text()).slice(0, 300);
    if ((r.status === 429 || r.status >= 500) && attempt < 6) {
      await new Promise((ok) => setTimeout(ok, 2000 * 2 ** (attempt - 1)));
      continue;
    }
    throw new Error(`speech request failed (${r.status}): ${body}`);
  }
}

// 1. A clip per line, requested three at a time.
const clips = [];
const jobs = [];
scenes.forEach((sc, si) => {
  sc.lines = sc.lines.map((l) => (typeof l === 'string' ? { t: l } : l));
  sc.lines.forEach((l, li) => {
    const file = path.join(AUD, `${String(si).padStart(2, '0')}-${sc.id}-${String(li).padStart(2, '0')}.wav`);
    const text = l.s ?? speak(l.t);
    const stamp = file + '.txt';
    const want = `${model}|${voice}|${text}`;
    if (!fs.existsSync(file) || !fs.existsSync(stamp) || fs.readFileSync(stamp, 'utf8') !== want) jobs.push({ text, file, stamp, want });
    l.file = file;
    clips.push(l);
  });
});
if (jobs.length) {
  const key = apiKey();
  let next = 0;
  let done = 0;
  await Promise.all([0, 1, 2].map(async () => {
    while (next < jobs.length) {
      const j = jobs[next++];
      await speech(j.text, j.file, key);
      fs.writeFileSync(j.stamp, j.want);
      if (++done % 10 === 0 || done === jobs.length) console.log(`  speech: ${done}/${jobs.length} lines`);
    }
  }));
}
for (const l of clips) {
  l.pcm = trim(readWav(l.file));
  l.dur = l.pcm.length / SR;
}

// 2. Timeline: scenes play back to back; lines inside a scene follow each other.
let t = 0;
const timeline = { fps, scenes: [] };
for (const sc of scenes) {
  let c = sc.lead ?? 0.6;
  const lines = sc.lines.map((l, i) => {
    if (i > 0) c += l.gap ?? 0.32;
    const line = { start: +c.toFixed(3), dur: +l.dur.toFixed(3), text: l.t };
    l.abs = t + c;
    c += l.dur;
    return line;
  });
  const dur = Math.max(c + (sc.tail ?? 1.2), sc.min ?? 0);
  timeline.scenes.push({ id: sc.id, chapter: sc.chapter, start: +t.toFixed(3), dur: +dur.toFixed(3), lines });
  t += dur;
}
// Whole frames only, so every frame maps to one time.
timeline.duration = Math.ceil(t * fps) / fps;
fs.writeFileSync(path.join(BUILD, 'timeline.js'), `globalThis.TIMELINE = ${JSON.stringify(timeline, null, 1)};\n`);

// 3. Voice track.
const N = Math.ceil(timeline.duration * SR);
const voiceTrack = new Float32Array(N);
let peak = 0;
for (const l of clips) {
  const o = Math.round(l.abs * SR);
  for (let i = 0; i < l.pcm.length && o + i < N; i++) {
    voiceTrack[o + i] += l.pcm[i];
    peak = Math.max(peak, Math.abs(l.pcm[i]));
  }
}
const vGain = 0.82 / peak;
for (let i = 0; i < N; i++) voiceTrack[i] *= vGain;

// 4. Music bed: a slow four-chord pad, detuned left and right, with a soft
//    swell at every scene change. Ducked while the voice speaks.
const chords = [
  [110.0, 164.81, 220.0, 261.63], // Am
  [87.31, 130.81, 174.61, 220.0], // F
  [130.81, 196.0, 261.63, 329.63], // C
  [98.0, 146.83, 196.0, 246.94], // G
];
const CH = 8; // seconds per chord
const XF = 3; // crossfade
const musicL = new Float32Array(N);
const musicR = new Float32Array(N);
const TAU = Math.PI * 2;
for (let i = 0; i < N; i++) {
  const s = i / SR;
  const k = Math.floor(s / CH);
  const into = s - k * CH;
  let sl = 0;
  let sr = 0;
  for (const [idx, w] of [[k, 1], [k - 1, 0]]) {
    let g = w;
    if (w === 1) g = into < XF ? 0.5 - 0.5 * Math.cos((Math.PI * into) / XF) : 1;
    else g = into < XF ? 0.5 + 0.5 * Math.cos((Math.PI * into) / XF) : 0;
    if (g <= 0 || idx < 0) continue;
    for (const f of chords[idx % chords.length]) {
      const tone = (ff) => Math.sin(TAU * ff * s) + 0.22 * Math.sin(TAU * 2 * ff * s) + 0.06 * Math.sin(TAU * 3 * ff * s);
      sl += g * tone(f * 1.0025);
      sr += g * tone(f * 0.9975);
    }
  }
  const trem = 0.82 + 0.18 * Math.sin(TAU * 0.06 * s);
  musicL[i] = sl * trem * 0.018;
  musicR[i] = sr * trem * 0.018;
}
// Scene-change swells: low-passed noise rising into each new scene.
let seed = 7;
const rnd = () => ((seed = (seed * 1664525 + 1013904223) >>> 0) / 4294967296) * 2 - 1;
for (const sc of timeline.scenes.slice(1)) {
  const len = Math.round(1.2 * SR);
  const o = Math.round((sc.start - 0.7) * SR);
  let y = 0;
  const a = 1 - Math.exp((-TAU * 700) / SR);
  for (let i = 0; i < len; i++) {
    const p = i / len;
    y += a * (rnd() - y);
    const env = Math.sin(Math.PI * p) ** 2;
    const j = o + i;
    if (j >= 0 && j < N) { musicL[j] += y * env * 0.05; musicR[j] += y * env * 0.05; }
  }
}
// Fade in over 4 s, out over the last 5 s.
for (let i = 0; i < N; i++) {
  const s = i / SR;
  const f = Math.min(1, s / 4, (timeline.duration - s) / 5);
  musicL[i] *= Math.max(0, f);
  musicR[i] *= Math.max(0, f);
}
// Ducking envelope from the known line times.
const duck = new Float32Array(N);
for (const l of clips) {
  const a = Math.round((l.abs - 0.25) * SR);
  const z = Math.round((l.abs + l.dur + 0.35) * SR);
  for (let i = Math.max(0, a); i < Math.min(N, z); i++) duck[i] = 1;
}
const smooth = 1 - Math.exp(-1 / (0.18 * SR));
let d = 0;
for (let i = 0; i < N; i++) { d += smooth * (duck[i] - d); duck[i] = d; }

writeWav(path.join(BUILD, 'music.wav'), [musicL.map((v) => v * 1.6), musicR.map((v) => v * 1.6)]);
const L = new Float32Array(N);
const R = new Float32Array(N);
// Leave the signal untouched below 0.9; only round off rare peaks above it.
const soft = (v) => (Math.abs(v) < 0.9 ? v : Math.sign(v) * (0.9 + 0.1 * Math.tanh((Math.abs(v) - 0.9) / 0.1)));
for (let i = 0; i < N; i++) {
  const g = 1 - 0.55 * duck[i];
  L[i] = soft(voiceTrack[i] + musicL[i] * g);
  R[i] = soft(voiceTrack[i] + musicR[i] * g);
}
writeWav(path.join(BUILD, 'narration.wav'), [L, R]);

// 5. Captions.
const ts = (x) => {
  const ms = Math.round(x * 1000);
  const h = Math.floor(ms / 3600000);
  const m = Math.floor((ms % 3600000) / 60000);
  const s = Math.floor((ms % 60000) / 1000);
  return `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')},${String(ms % 1000).padStart(3, '0')}`;
};
const srt = clips.map((l, i) => `${i + 1}\n${ts(l.abs)} --> ${ts(l.abs + l.dur + 0.2)}\n${l.t}\n`).join('\n');
fs.writeFileSync(path.join(OUT, 'captions.srt'), srt);

// 6. The narration as a script with timestamps, for recording a voice-over
//    on top of the version without the voice.
const mmss = (x) => `${Math.floor(x / 60)}:${String(Math.floor(x % 60)).padStart(2, '0')}`;
let md = '# Secure GPU Stack walkthrough: narration script\n\n';
md += 'Each line starts at the time shown. To record your own voice, play\n';
md += '`secure-gpu-stack-no-voice.mp4` and read along; the captions show each\n';
md += 'line as it comes up. Regenerate with `node video/build-audio.mjs`.\n';
timeline.scenes.forEach((sc, i) => {
  md += `\n## ${mmss(sc.start)} ${sc.chapter ?? (i === 0 ? 'Opening' : i === 1 ? 'Title' : 'Closing')}\n\n`;
  for (const l of sc.lines) md += `- **${mmss(sc.start + l.start)}** ${l.text}\n`;
});
fs.writeFileSync(path.join(OUT, 'narration-script.md'), md);

const m = Math.floor(timeline.duration / 60);
const s = Math.round(timeline.duration % 60);
console.log(`${clips.length} lines, ${scenes.length} scenes, ${m}:${String(s).padStart(2, '0')} total`);
for (const sc of timeline.scenes) console.log(`  ${sc.start.toFixed(1).padStart(6)}s  ${sc.dur.toFixed(1).padStart(5)}s  ${sc.id}`);
