// The web reader's host page (served at /read/<index>).
//
// Runs in the user's own desktop browser, so JavaScript is fine here
// (unlike the plain-HTML home page). It loads the vendored foliate-js
// `view.js` from /reader-assets/, fetches the book bytes from
// /book/<index>, and provides the UI: table-of-contents sidebar, prev /
// next paging with arrow keys, saved position, font size and a
// light / dark theme. Position and settings live in the browser's
// localStorage, keyed per book.
//
// Large books: the page does NOT download the whole file before showing
// anything. A 1-byte Range probe finds the size; big epub / cbz / mobi
// books are then opened through a file-like object that fetches byte
// ranges on demand (and falls back to a full download with a progress
// readout if that fails); everything else is downloaded with progress.
// The script lives in a raw string ([_readerScript]) so JavaScript needs
// no Dart escaping; only the per-book values are interpolated, through
// a small config <script>.
import 'dart:convert';

/// Minimal HTML escaping for text placed in element content / attributes.
String escapeHtml(String s) =>
    const HtmlEscape(HtmlEscapeMode.attribute).convert(s);

/// JSON string literal that is safe inside an inline <script>.
String _jsString(String s) =>
    jsonEncode(s).replaceAll('<', r'\u003c').replaceAll('>', r'\u003e');

/// Build the reader page for the book at snapshot [index].
///
/// [bookKey] identifies the book for the saved position (stable across
/// service restarts: it is derived from the book's own identity, not
/// from [index], which only lives for one snapshot).
String buildReaderPage({
  required int index,
  required String title,
  required String bookKey,
}) {
  return '''<!DOCTYPE html>
<html lang="zh">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escapeHtml(title)}</title>
<style>
  :root { --bg:#fbfaf7; --fg:#1d1d1f; --bar:#efece4; --line:#d8d3c6; --accent:#2f6f4f; }
  :root[data-theme="dark"] { --bg:#16181a; --fg:#d9d9d6; --bar:#202326; --line:#33373b; --accent:#7fc29b; }
  * { box-sizing: border-box; }
  html, body { height: 100%; margin: 0; background: var(--bg); color: var(--fg);
    font-family: system-ui, -apple-system, "Segoe UI", "PingFang SC", "Microsoft YaHei", sans-serif; }
  #app { display: flex; flex-direction: column; height: 100%; }
  #bar { display: flex; align-items: center; gap: 8px; padding: 6px 10px;
    background: var(--bar); border-bottom: 1px solid var(--line); }
  #bar .title { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 14px; }
  button { background: transparent; color: var(--fg); border: 1px solid var(--line);
    border-radius: 6px; padding: 4px 10px; font-size: 14px; cursor: pointer; }
  button:hover { border-color: var(--accent); }
  #main { flex: 1; display: flex; min-height: 0; }
  #toc { width: 280px; overflow: auto; padding: 8px 0; background: var(--bar);
    border-right: 1px solid var(--line); }
  #toc[hidden] { display: none; }
  #toc a { display: block; padding: 6px 14px; color: var(--fg); text-decoration: none;
    font-size: 13px; line-height: 1.4; }
  #toc a:hover { background: var(--line); }
  #toc a.sub { padding-left: 28px; }
  #stage { flex: 1; min-width: 0; position: relative; }
  #status { position: absolute; inset: 0; display: flex; align-items: center;
    justify-content: center; padding: 24px; text-align: center; line-height: 1.6; }
  #status[hidden] { display: none; }
  foliate-view { display: block; width: 100%; height: 100%; }
  #foot { display: flex; align-items: center; justify-content: space-between;
    padding: 4px 12px; font-size: 12px; background: var(--bar); border-top: 1px solid var(--line); }
</style>
</head>
<body>
<div id="app">
  <div id="bar">
    <button id="btn-toc" title="Contents">☰</button>
    <div class="title">${escapeHtml(title)}</div>
    <button id="btn-font-" title="A−">A−</button>
    <button id="btn-font+" title="A+">A+</button>
    <button id="btn-theme" title="Theme">◐</button>
    <button id="btn-prev" title="←">‹</button>
    <button id="btn-next" title="→">›</button>
  </div>
  <div id="main">
    <nav id="toc" hidden></nav>
    <div id="stage">
      <div id="status">…</div>
    </div>
  </div>
  <div id="foot"><span id="where"></span><a href="/" style="color:var(--accent)">⌂</a></div>
</div>
<script>window.__ZLIBX = { url: ${_jsString('/book/$index')}, key: ${_jsString(bookKey)} };</script>
<script type="module">
$_readerScript
</script>
</body>
</html>''';
}

/// The reader page's script (see the file header). A raw string: `$`
/// and backslashes are JavaScript here, not Dart.
const String _readerScript = r'''const CFG = window.__ZLIBX;
const BOOK_URL = CFG.url;
const BOOK_KEY = CFG.key;
const POS_KEY = 'zlibx:pos:' + BOOK_KEY;
const FONT_KEY = 'zlibx:font';
const THEME_KEY = 'zlibx:theme';

// ── Large-book loading ──
// Books below LAZY_MIN are fetched whole (one request beats many).
// Bigger zip/PDB-based books (epub, cbz, mobi, azw3) are NOT
// downloaded up front: the reader gets a file-like object that pulls
// byte ranges on demand, so a 300 MB comic opens as soon as its
// directory has been read and only the pages you turn to are fetched.
const LAZY_MIN = 8 * 1024 * 1024;
const BLOCK = 256 * 1024;
const MAX_BLOCKS = 48; // ~12 MB of cached blocks
const LAZY_EXT = new Set(['epub', 'cbz', 'mobi', 'azw3', 'azw']);

const zh = /^zh/i.test(navigator.language || '');
const T = zh ? {
  loading: '正在加载', opening: '正在打开…', parsing: '正在解析…',
  noLib: '阅读器组件未安装（assets/web-reader/ 为空），见 VENDORED.md。',
  loadFail: '无法加载这本书', openFail: '无法打开这本书',
} : {
  loading: 'Loading', opening: 'Opening…', parsing: 'Parsing…',
  noLib: 'Reader library is not installed (assets/web-reader/ is empty). See VENDORED.md.',
  loadFail: 'Could not load this book', openFail: 'Could not open this book',
};

// localStorage can be missing or full (private mode): never let that
// break reading.
const store = {
  get(k) { try { return localStorage.getItem(k); } catch (e) { return null; } },
  set(k, v) { try { localStorage.setItem(k, v); } catch (e) { /* noop */ } },
};

const $ = (id) => document.getElementById(id);
const status = $('status');
let fatal = false;
const say = (msg) => { status.hidden = false; status.textContent = msg; };
const fail = (msg) => { fatal = true; say(msg); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const fmtMB = (n) => (n / 1048576).toFixed(n >= 10485760 ? 0 : 1) + ' MB';

// ── Theme ──
let theme = store.get(THEME_KEY) ||
  (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light');
const applyTheme = () => {
  document.documentElement.dataset.theme = theme;
  applyStyle();
};
$('btn-theme').onclick = () => {
  theme = theme === 'dark' ? 'light' : 'dark';
  store.set(THEME_KEY, theme);
  applyTheme();
};

// ── Font size ──
let fontPct = Math.min(250, Math.max(60, parseInt(store.get(FONT_KEY) || '100', 10) || 100));
$('btn-font-').onclick = () => { fontPct = Math.max(60, fontPct - 10); store.set(FONT_KEY, String(fontPct)); applyStyle(); };
$('btn-font+').onclick = () => { fontPct = Math.min(250, fontPct + 10); store.set(FONT_KEY, String(fontPct)); applyStyle(); };

let view = null;
function applyStyle() {
  if (!view || !view.renderer) return;
  const dark = theme === 'dark';
  const css = 'html{color:' + (dark ? '#d9d9d6' : '#1d1d1f') + '!important;background:' +
    (dark ? '#16181a' : '#fbfaf7') + '!important;font-size:' + fontPct + '%!important;}' +
    'a{color:' + (dark ? '#7fc29b' : '#2f6f4f') + '!important;}';
  try { view.renderer.setStyles(css); } catch (e) { /* noop */ }
}

// ── Paging ──
const prev = () => view && view.prev();
const next = () => view && view.next();
$('btn-prev').onclick = prev;
$('btn-next').onclick = next;
const onKey = (e) => {
  if (e.key === 'ArrowLeft' || e.key === 'PageUp') { e.preventDefault(); prev(); }
  else if (e.key === 'ArrowRight' || e.key === 'PageDown' || e.key === ' ') { e.preventDefault(); next(); }
};
addEventListener('keydown', onKey);

// ── Contents ──
$('btn-toc').onclick = () => { $('toc').hidden = !$('toc').hidden; };
function renderToc(items, depth = 0) {
  const nav = $('toc');
  for (const item of items || []) {
    const a = document.createElement('a');
    a.textContent = item.label || '';
    a.href = '#';
    if (depth) a.className = 'sub';
    a.onclick = (e) => { e.preventDefault(); view.goTo(item.href); };
    nav.appendChild(a);
    if (item.subitems) renderToc(item.subitems, depth + 1);
  }
}

// ── A file-like object backed by HTTP Range requests ──
// foliate-js (and the zip.js inside it) only ever call size, name,
// type, slice(a, b).arrayBuffer() and arrayBuffer() on the book, so
// this is enough to stand in for a File without holding the book.
const clampIndex = (v, size, dflt) =>
  v === undefined ? dflt : v < 0 ? Math.max(0, size + v) : Math.min(v, size);

class RangeSlice {
  constructor(file, start, end) { this.file = file; this.start = start; this.end = end; }
  get size() { return this.end - this.start; }
  get type() { return ''; }
  slice(a, b) {
    const s = clampIndex(a, this.size, 0);
    const e = clampIndex(b, this.size, this.size);
    return new RangeSlice(this.file, this.start + s, this.start + Math.max(s, e));
  }
  arrayBuffer() { return this.file.read(this.start, this.end); }
  async text() { return new TextDecoder().decode(await this.arrayBuffer()); }
}

class RangeFile {
  constructor(url, size, name, type) {
    this.url = url; this.size = size; this.name = name; this.type = type;
    this.blocks = new Map();   // block index -> Uint8Array, in LRU order
    this.pending = new Map();  // block index -> Promise<Uint8Array>
  }
  slice(a, b) {
    const s = clampIndex(a, this.size, 0);
    const e = clampIndex(b, this.size, this.size);
    return new RangeSlice(this, s, Math.max(s, e));
  }
  arrayBuffer() { return this.read(0, this.size); }
  async text() { return new TextDecoder().decode(await this.arrayBuffer()); }

  async read(start, end) {
    if (end <= start) return new ArrayBuffer(0);
    // A big read goes straight through; only small, repeated reads
    // (zip headers, directory, 64 KB inflate chunks) use the cache.
    if (end - start >= BLOCK * 4) return this.fetchRange(start, end);
    const first = Math.floor(start / BLOCK);
    const last = Math.floor((end - 1) / BLOCK);
    const wanted = [];
    for (let i = first; i <= last; i++) wanted.push(this.block(i));
    const parts = await Promise.all(wanted);
    const out = new Uint8Array(end - start);
    let pos = 0;
    for (let i = first; i <= last; i++) {
      const blk = parts[i - first];
      const base = i * BLOCK;
      const from = Math.max(start, base) - base;
      const to = Math.min(end, base + blk.length) - base;
      out.set(blk.subarray(from, to), pos);
      pos += to - from;
    }
    return out.buffer;
  }

  block(i) {
    const hit = this.blocks.get(i);
    if (hit) { this.blocks.delete(i); this.blocks.set(i, hit); return Promise.resolve(hit); }
    let p = this.pending.get(i);
    if (!p) {
      const s = i * BLOCK;
      const e = Math.min(this.size, s + BLOCK);
      p = this.fetchRange(s, e).then((buf) => {
        const u = new Uint8Array(buf);
        this.blocks.set(i, u);
        while (this.blocks.size > MAX_BLOCKS) this.blocks.delete(this.blocks.keys().next().value);
        this.pending.delete(i);
        return u;
      }, (err) => { this.pending.delete(i); throw err; });
      this.pending.set(i, p);
    }
    return p;
  }

  async fetchRange(start, end) {
    for (let attempt = 0; ; attempt++) {
      try {
        const r = await fetch(this.url, { headers: { Range: 'bytes=' + start + '-' + (end - 1) } });
        if (r.status !== 206) throw new Error('range ' + r.status);
        const buf = await r.arrayBuffer();
        if (buf.byteLength !== end - start) throw new Error('short read');
        return buf;
      } catch (e) {
        // The phone may be mid-wifi-hiccup: a couple of quick retries.
        if (attempt >= 2) throw e;
        await sleep(250 * (attempt + 1));
      }
    }
  }
}

// ── Whole-book download, with a progress readout ──
async function readWithProgress(resp, total, type) {
  if (!resp.body || !resp.body.getReader) return resp.blob();
  const reader = resp.body.getReader();
  const chunks = [];
  let got = 0;
  let last = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    chunks.push(value);
    got += value.length;
    const now = performance.now();
    if (now - last > 120) {
      last = now;
      say(T.loading + ' ' + (total ? Math.floor(got * 100 / total) + '% (' + fmtMB(got) + ' / ' + fmtMB(total) + ')' : fmtMB(got)));
    }
  }
  return new Blob(chunks, { type });
}

// A 1-byte Range probe: tells us the size and whether the server can
// do ranges, without committing to a full download.
async function probe() {
  const r = await fetch(BOOK_URL, { headers: { Range: 'bytes=0-0' } });
  const name = r.headers.get('X-Book-Name') || 'book';
  const type = r.headers.get('Content-Type') || '';
  if (r.status === 206) {
    const m = /\/(\d+)\s*$/.exec(r.headers.get('Content-Range') || '');
    try { await r.arrayBuffer(); } catch (e) { /* noop */ }
    return { ranged: !!m, total: m ? parseInt(m[1], 10) : 0, name, type, response: null };
  }
  if (r.ok) {
    // No Range support: this response already IS the whole book.
    return { ranged: false, total: 0, name, type, response: r };
  }
  const err = new Error('book ' + r.status);
  err.status = r.status;
  throw err;
}

async function fetchWhole(info) {
  const resp = info.response || await fetch(BOOK_URL);
  if (!resp.ok) { const err = new Error('book ' + resp.status); err.status = resp.status; throw err; }
  const total = info.total || parseInt(resp.headers.get('Content-Length') || '0', 10) || 0;
  say(T.loading + ' …');
  const blob = await readWithProgress(resp, total, info.type);
  say(T.parsing);
  return new File([blob], info.name, { type: info.type });
}

// ── View ──
function makeView() {
  const v = document.createElement('foliate-view');
  $('stage').appendChild(v);
  v.addEventListener('relocate', (e) => {
    const d = e.detail || {};
    if (d.cfi) store.set(POS_KEY, d.cfi);
    if (typeof d.fraction === 'number') $('where').textContent = Math.round(d.fraction * 100) + '%';
  });
  v.addEventListener('load', (e) => {
    // Arrow keys must also work while focus is inside the book iframe.
    const doc = e.detail && e.detail.doc;
    if (doc) doc.addEventListener('keydown', onKey);
  });
  view = v;
  return v;
}

function dropView() {
  if (!view) return;
  try { if (view.close) view.close(); } catch (e) { /* noop */ }
  try { view.remove(); } catch (e) { /* noop */ }
  view = null;
}

async function openBook(file) {
  const v = makeView();
  await v.open(file);
}

async function finishOpen() {
  status.hidden = true;
  $('toc').textContent = '';
  renderToc(view.book && view.book.toc);
  applyTheme();
  const saved = store.get(POS_KEY);
  if (saved) { try { await view.goTo(saved); } catch (e) { await view.goToFraction(0); } }
  else { await view.goToFraction(0); }
}

// ── Boot ──
try {
  try {
    await import('/reader-assets/view.js');
  } catch (e) {
    fail(T.noLib);
    throw e;
  }

  let info;
  try {
    info = await probe();
  } catch (e) {
    fail(T.loadFail + (e.status ? ' (' + e.status + ')' : ''));
    throw e;
  }

  const ext = ((info.name.split('.').pop()) || '').toLowerCase();
  let opened = false;
  if (info.ranged && info.total >= LAZY_MIN && LAZY_EXT.has(ext)) {
    say(T.opening);
    try {
      await openBook(new RangeFile(BOOK_URL, info.total, info.name, info.type));
      opened = true;
    } catch (e) {
      // Lazy reading is an optimisation: whatever went wrong, the
      // plain full download below is the safe path.
      console.warn('lazy open failed, falling back to a full download', e);
      dropView();
    }
  }
  if (!opened) {
    let file;
    try {
      file = await fetchWhole(info);
    } catch (e) {
      fail(T.loadFail + (e.status ? ' (' + e.status + ')' : ''));
      throw e;
    }
    await openBook(file);
  }
  await finishOpen();
} catch (e) {
  console.error(e);
  if (!fatal) fail(T.openFail);
}
''';
