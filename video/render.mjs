// Renders stage.html to video, frame by frame, through a headless Chromium
// browser (Microsoft Edge or Google Chrome) driven over the DevTools protocol.
// No npm packages: Node's built-in WebSocket talks to the browser.
//
//   node video/render.mjs --stills 12.5,40,61.2   PNGs in build/stills/
//   node video/render.mjs                         the full video, in out/
//   node video/render.mjs --workers 6             parallel browsers (default 5)
//   node video/render.mjs video/m2 [...]          another video's folder
//
// The folder holds stage.html, build/ and out/ (default: video/ itself).
// Needs ffmpeg, and build/timeline.js and build/narration.wav from
// build-audio.mjs.

import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
// The first argument that isn't an option or an option's value.
const folderArg = process.argv.slice(2).find((a, i, all) => !a.startsWith('--') && !['--stills', '--workers'].includes(all[i - 1]));
const DIR = folderArg ? path.resolve(folderArg) : HERE;
const BUILD = path.join(DIR, 'build');
const OUT = path.join(DIR, 'out');
const W = 1920, H = 1080;
const BROWSERS = [
  '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
];
const BROWSER = process.env.BROWSER || BROWSERS.find((b) => fs.existsSync(b));
if (!BROWSER) throw new Error('No Chromium browser found; set BROWSER');

const arg = (name, dflt) => { const i = process.argv.indexOf(name); return i < 0 ? dflt : process.argv[i + 1]; };
const stills = arg('--stills', null);
const workers = +arg('--workers', 5);

await import(pathToFileURL(path.join(BUILD, 'timeline.js')).href);
const { fps, duration, name = 'secure-gpu-stack' } = globalThis.TIMELINE;
const frames = Math.round(duration * fps);
const pageUrl = pathToFileURL(path.join(DIR, 'stage.html')).href;

async function openBrowser(n) {
  const profile = path.join(BUILD, `browser-profile-${n}`);
  fs.mkdirSync(profile, { recursive: true });
  const port = 9400 + n;
  const proc = spawn(BROWSER, [
    '--headless=new', `--remote-debugging-port=${port}`, `--user-data-dir=${profile}`,
    '--no-first-run', '--no-default-browser-check', '--hide-scrollbars', '--mute-audio',
    '--force-device-scale-factor=1', `--window-size=${W},${H}`, '--force-color-profile=srgb',
    '--disable-background-timer-throttling', '--disable-renderer-backgrounding',
    '--disable-extensions', '--disable-sync', 'about:blank',
  ], { stdio: 'ignore' });
  let target;
  for (let i = 0; i < 100 && !target; i++) {
    await new Promise((r) => setTimeout(r, 150));
    try { target = (await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()).find((x) => x.type === 'page'); } catch {}
  }
  if (!target) throw new Error('browser did not start');
  const ws = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((r, j) => { ws.onopen = r; ws.onerror = j; });
  let id = 0;
  const pending = new Map();
  const waiters = [];
  ws.onmessage = (m) => {
    const msg = JSON.parse(m.data);
    if (msg.id && pending.has(msg.id)) {
      const { res, rej } = pending.get(msg.id); pending.delete(msg.id);
      msg.error ? rej(new Error(msg.error.message)) : res(msg.result);
    } else if (msg.method) {
      for (const w of waiters.splice(0)) w(msg);
    }
  };
  const send = (method, params = {}) => new Promise((res, rej) => { const i = ++id; pending.set(i, { res, rej }); ws.send(JSON.stringify({ id: i, method, params })); });
  const event = (name) => new Promise((r) => { const f = (msg) => (msg.method === name ? r(msg) : waiters.push(f)); waiters.push(f); });
  await send('Page.enable');
  await send('Emulation.setDeviceMetricsOverride', { width: W, height: H, deviceScaleFactor: 1, mobile: false });
  const loaded = event('Page.loadEventFired');
  await send('Page.navigate', { url: pageUrl });
  await loaded;
  await send('Runtime.evaluate', { expression: 'document.fonts.ready.then(() => 1)', awaitPromise: true });
  const evalOk = await send('Runtime.evaluate', { expression: 'typeof seek', returnByValue: true });
  if (evalOk.result.value !== 'function') throw new Error('stage.html failed to load (seek missing)');
  const shot = async (t) => {
    const r = await send('Runtime.evaluate', { expression: `seek(${t}); 1`, returnByValue: true });
    if (r.exceptionDetails) throw new Error(`seek(${t}): ${r.exceptionDetails.exception?.description}`);
    const { data } = await send('Page.captureScreenshot', { format: 'png', fromSurface: true });
    return Buffer.from(data, 'base64');
  };
  const close = () => { try { ws.close(); } catch {} proc.kill(); };
  return { shot, close };
}

if (stills) {
  const dir = path.join(BUILD, 'stills');
  fs.mkdirSync(dir, { recursive: true });
  const b = await openBrowser(0);
  for (const t of stills.split(',').map(Number)) {
    const f = path.join(dir, `t${t.toFixed(2).padStart(7, '0')}.png`);
    fs.writeFileSync(f, await b.shot(t));
    console.log(f);
  }
  b.close();
  process.exit(0);
}

const video = path.join(BUILD, 'video.mp4');
const run = (args) => { const r = spawnSync('ffmpeg', ['-y', '-loglevel', 'error', ...args], { stdio: 'inherit' }); if (r.status !== 0) throw new Error('ffmpeg failed'); };
const mux = (audio, file) => run(['-i', video, '-i', audio, '-map', '0:v', '-map', '1:a', '-c:v', 'copy', '-c:a', 'aac', '-b:a', '192k', '-shortest', '-movflags', '+faststart', path.join(OUT, file)]);
const muxAll = () => {
  mux(path.join(BUILD, 'narration.wav'), `${name}.mp4`);
  mux(path.join(BUILD, 'music.wav'), `${name}-no-voice.mp4`);
};
// After changing only the audio: reuse build/video.mp4.
if (process.argv.includes('--mux-only')) { fs.mkdirSync(OUT, { recursive: true }); muxAll(); process.exit(0); }

// Full render: each worker takes a contiguous range of frames and pipes them
// into its own ffmpeg; the segments are joined without re-encoding.
fs.mkdirSync(OUT, { recursive: true });
const per = Math.ceil(frames / workers);
const started = Date.now();
let done = 0;
const segs = await Promise.all(Array.from({ length: workers }, async (_, w) => {
  const a = w * per, z = Math.min(frames, a + per);
  const seg = path.join(BUILD, `seg-${w}.mp4`);
  const ff = spawn('ffmpeg', ['-y', '-loglevel', 'error', '-f', 'image2pipe', '-framerate', String(fps), '-c:v', 'png', '-i', '-',
    '-c:v', 'libx264', '-preset', 'slow', '-crf', '17', '-tune', 'animation', '-pix_fmt', 'yuv420p', '-r', String(fps), seg], { stdio: ['pipe', 'inherit', 'inherit'] });
  const finished = new Promise((r, j) => ff.on('close', (c) => (c === 0 ? r() : j(new Error(`ffmpeg exit ${c}`)))));
  const b = await openBrowser(w + 1);
  for (let f = a; f < z; f++) {
    const png = await b.shot(f / fps);
    if (!ff.stdin.write(png)) await new Promise((r) => ff.stdin.once('drain', r));
    if (++done % 300 === 0) {
      const s = (Date.now() - started) / 1000;
      console.log(`${done}/${frames} frames, ${s.toFixed(0)} s, ~${((frames - done) * s / done).toFixed(0)} s left`);
    }
  }
  b.close();
  ff.stdin.end();
  await finished;
  return seg;
}));
const list = path.join(BUILD, 'segments.txt');
fs.writeFileSync(list, segs.map((s) => `file '${s}'`).join('\n'));
run(['-f', 'concat', '-safe', '0', '-i', list, '-c', 'copy', video]);
muxAll();
console.log(`done in ${((Date.now() - started) / 1000).toFixed(0)} s: ${path.join(OUT, `${name}.mp4`)}`);
