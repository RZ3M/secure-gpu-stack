// Shared by every video in this folder: the toolkit scenes are built with
// (everything is a pure function of time t) and the engine that plays them.
// A stage.html loads this, defines its scenes with def(), then calls run().

// ---------- toolkit: everything is a pure function of time t ----------
const clamp = (x, a = 0, b = 1) => (x < a ? a : x > b ? b : x);
const lerp = (a, b, p) => a + (b - a) * p;
const E = {
  lin: (p) => p,
  out: (p) => 1 - Math.pow(1 - p, 3),
  inOut: (p) => (p < 0.5 ? 4 * p * p * p : 1 - Math.pow(-2 * p + 2, 3) / 2),
  back: (p) => { const c1 = 1.5, c3 = c1 + 1; return 1 + c3 * Math.pow(p - 1, 3) + c1 * Math.pow(p - 1, 2); },
};
// Progress of a tween that starts at t0 and lasts d.
const P = (t, t0, d = 0.6, e = E.out) => e(clamp((t - t0) / d));
// Visible from a, gone by b.
const W = (t, a, b, fi = 0.55, fo = 0.45) => Math.min(P(t, a, fi), 1 - P(t, b, fo, E.inOut));
function vis(el, p, { x = 0, y = 26, s = 1 } = {}) {
  el.style.opacity = p;
  el.style.transform = p >= 1 ? '' : `translate(${(1 - p) * x}px, ${(1 - p) * y}px) scale(${s + (1 - s) * p})`;
}
function stamp(el, p, rot = -7) {
  el.style.opacity = clamp(p * 3);
  el.style.transform = `rotate(${rot}deg) scale(${p <= 0 ? 1.8 : lerp(1.8, 1, E.back(p))})`;
}
const fmt = (n) => Math.round(n).toLocaleString('en-US');
function h(html) { const d = document.createElement('div'); d.innerHTML = html.trim(); return d.firstElementChild; }
// Place an element absolutely in a scene, hidden until a tween shows it.
function A(root, x, y, html, w, show = false) {
  const e = h(html);
  e.style.position = 'absolute';
  e.style.left = x + 'px';
  e.style.top = y + 'px';
  if (w) e.style.width = w + 'px';
  e.style.opacity = show ? 1 : 0;
  root.appendChild(e);
  return e;
}
const LOGO = (size) => `<svg viewBox="0 0 200 200" width="${size}" height="${size}" class="logo">
  <rect class="lg-body" x="50" y="50" width="100" height="100" rx="16" pathLength="1"/>
  <path class="lg-pin" pathLength="1" d="M66 50V28M83 50V28M100 50V28M117 50V28M134 50V28M66 150V172M83 150V172M100 150V172M117 150V172M134 150V172M50 66H28M50 83H28M50 100H28M50 117H28M50 134H28M150 66H172M150 83H172M150 100H172M150 117H172M150 134H172"/>
  <path class="lg-shield" pathLength="1" d="M100 70L125 80V100C125 116 114 126 100 131C86 126 75 116 75 100V80Z"/>
  <path class="lg-check" pathLength="1" d="M88 101L97 110L113 92"/>
</svg>`;
function drawLogo(svg, t, t0) {
  const parts = [['.lg-body', 0, 1.0], ['.lg-pin', 0.4, 1.0], ['.lg-shield', 0.8, 0.9], ['.lg-check', 1.4, 0.5]];
  for (const [sel, d0, d] of parts) svg.querySelector(sel).style.strokeDashoffset = 1 - P(t, t0 + d0, d, E.inOut);
}
const head = (R, kicker, title, kc = '') => [
  A(R, 120, 168, `<div class="kicker ${kc}">${kicker}</div>`),
  A(R, 120, 204, `<div class="h2">${title}</div>`, 1680),
];

// ---------- scenes register here ----------
const SCN = {};
const def = (id, glow, build) => (SCN[id] = { glow, build });

// ---------- engine: call once the scenes are defined ----------
function run() {
  const TL = globalThis.TIMELINE;
  window.DURATION = TL.duration;
  window.FPS = TL.fps;
  const stageEl = document.getElementById('stage');
  const glow = document.getElementById('glow');
  const capEl = document.querySelector('#cap span');
  const hudEl = document.getElementById('hud');
  const chB = document.querySelector('#hud .ch b'), chS = document.querySelector('#hud .ch span');
  const progI = document.querySelector('#prog i');
  let chapterNo = 0;
  const live = TL.scenes.map((sc) => {
    const root = document.createElement('div');
    root.className = 'scene';
    root.style.display = 'none';
    stageEl.appendChild(root);
    const S = { dur: sc.dur, L: sc.lines.map((l) => l.start), E: sc.lines.map((l) => l.start + l.dur), T: sc.lines.map((l) => l.text) };
    // Roughly when a phrase is spoken inside line i, by its position in the text.
    S.w = (i, phrase) => {
      const k = S.T[i].indexOf(phrase);
      if (k < 0) throw new Error(`${sc.id}: "${phrase}" not in line ${i}`);
      return S.L[i] + ((S.E[i] - S.L[i]) * k) / S.T[i].length;
    };
    const def = SCN[sc.id];
    const update = def.build(root, S);
    const no = sc.chapter ? ++chapterNo : 0;
    return { sc, root, S, update, glow: def.glow, no };
  });
  for (const x of live) if (x.no) { const u = document.createElement('u'); u.style.left = (100 * x.sc.start / TL.duration) + '%'; document.getElementById('prog').appendChild(u); }

  let shown = -1;
  window.seek = function (t) {
    let i = live.findIndex((x) => t >= x.sc.start && t < x.sc.start + x.sc.dur);
    if (i < 0) i = t < 0 ? 0 : live.length - 1;
    const x = live[i];
    if (i !== shown) { live.forEach((y, j) => (y.root.style.display = j === i ? 'block' : 'none')); shown = i; }
    const lt = t - x.sc.start;
    const f = clamp(Math.min(lt / 0.45, (x.sc.dur - lt) / 0.45));
    x.root.style.opacity = f;
    if (x.sc.id !== 'outro') stageEl.style.opacity = 1;
    x.update(lt);

    const [r, g, b] = x.glow;
    const gx = 960 + 380 * Math.sin(t * 0.11 + i), gy = 520 + 180 * Math.cos(t * 0.09 + i * 1.7);
    glow.style.left = gx - 800 + 'px'; glow.style.top = gy - 800 + 'px';
    glow.style.background = `radial-gradient(closest-side, rgba(${r},${g},${b},${0.13 * f}), rgba(${r},${g},${b},0))`;

    hudEl.style.opacity = x.no ? f : 0;
    if (x.no) { chB.textContent = String(x.no).padStart(2, '0'); chS.textContent = x.sc.chapter; }
    progI.style.width = (100 * t / TL.duration) + '%';

    let cap = '';
    let cp = 0;
    for (const l of x.sc.lines) {
      if (lt >= l.start - 0.05 && lt < l.start + l.dur + 0.3) { cap = l.text; cp = Math.min(P(lt, l.start - 0.05, 0.15), 1 - P(lt, l.start + l.dur + 0.15, 0.15)); }
    }
    capEl.textContent = cap;
    capEl.parentElement.style.opacity = cap ? cp : 0;
  };
  const q = new URLSearchParams(location.search);
  window.seek(q.has('t') ? +q.get('t') : 0);
}
