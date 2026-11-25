// The web reader's host page (served at /read/<index>).
//
// Runs in the user's own desktop browser, so JavaScript is fine here
// (unlike the plain-HTML home page). It loads the vendored foliate-js
// `view.js` from /reader-assets/, fetches the book bytes from
// /book/<index>, and provides the UI: table-of-contents sidebar, prev /
// next paging with arrow keys, saved position, font size and a
// light / dark theme. Position and settings live in the browser's
// localStorage, keyed per book.
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
<script type="module">
const BOOK_URL = ${_jsString('/book/$index')};
const BOOK_KEY = ${_jsString(bookKey)};
const POS_KEY = 'zlibx:pos:' + BOOK_KEY;
const FONT_KEY = 'zlibx:font';
const THEME_KEY = 'zlibx:theme';

// localStorage can be missing or full (private mode): never let that
// break reading.
const store = {
  get(k) { try { return localStorage.getItem(k); } catch (e) { return null; } },
  set(k, v) { try { localStorage.setItem(k, v); } catch (e) {} },
};

const \$ = (id) => document.getElementById(id);
const status = \$('status');
const say = (msg) => { status.hidden = false; status.textContent = msg; };

// ── Theme ──
let theme = store.get(THEME_KEY) ||
  (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light');
const applyTheme = () => {
  document.documentElement.dataset.theme = theme;
  applyStyle();
};
\$('btn-theme').onclick = () => {
  theme = theme === 'dark' ? 'light' : 'dark';
  store.set(THEME_KEY, theme);
  applyTheme();
};

// ── Font size ──
let fontPct = Math.min(250, Math.max(60, parseInt(store.get(FONT_KEY) || '100', 10) || 100));
\$('btn-font-').onclick = () => { fontPct = Math.max(60, fontPct - 10); store.set(FONT_KEY, String(fontPct)); applyStyle(); };
\$('btn-font+').onclick = () => { fontPct = Math.min(250, fontPct + 10); store.set(FONT_KEY, String(fontPct)); applyStyle(); };

let view = null;
function applyStyle() {
  if (!view || !view.renderer) return;
  const dark = theme === 'dark';
  const css = 'html{color:' + (dark ? '#d9d9d6' : '#1d1d1f') + '!important;background:' +
    (dark ? '#16181a' : '#fbfaf7') + '!important;font-size:' + fontPct + '%!important;}' +
    'a{color:' + (dark ? '#7fc29b' : '#2f6f4f') + '!important;}';
  try { view.renderer.setStyles(css); } catch (e) {}
}

// ── Paging ──
const prev = () => view && view.prev();
const next = () => view && view.next();
\$('btn-prev').onclick = prev;
\$('btn-next').onclick = next;
const onKey = (e) => {
  if (e.key === 'ArrowLeft' || e.key === 'PageUp') { e.preventDefault(); prev(); }
  else if (e.key === 'ArrowRight' || e.key === 'PageDown' || e.key === ' ') { e.preventDefault(); next(); }
};
addEventListener('keydown', onKey);

// ── Contents ──
\$('btn-toc').onclick = () => { \$('toc').hidden = !\$('toc').hidden; };
function renderToc(items, depth = 0) {
  const nav = \$('toc');
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

// ── Boot ──
try {
  await import('/reader-assets/view.js');
} catch (e) {
  say('Reader library is not installed (assets/web-reader/ is empty). See VENDORED.md.');
  throw e;
}

try {
  const resp = await fetch(BOOK_URL);
  if (!resp.ok) { say('Could not load this book (' + resp.status + ').'); throw new Error('book ' + resp.status); }
  const blob = await resp.blob();
  const name = resp.headers.get('X-Book-Name') || 'book';
  const file = new File([blob], name, { type: blob.type });

  view = document.createElement('foliate-view');
  \$('stage').appendChild(view);
  view.addEventListener('relocate', (e) => {
    const d = e.detail || {};
    if (d.cfi) store.set(POS_KEY, d.cfi);
    if (typeof d.fraction === 'number') \$('where').textContent = Math.round(d.fraction * 100) + '%';
  });
  view.addEventListener('load', (e) => {
    // Arrow keys must also work while focus is inside the book iframe.
    const doc = e.detail && e.detail.doc;
    if (doc) doc.addEventListener('keydown', onKey);
  });

  await view.open(file);
  status.hidden = true;
  renderToc(view.book && view.book.toc);
  applyTheme();
  const saved = store.get(POS_KEY);
  if (saved) { try { await view.goTo(saved); } catch (e) { await view.goToFraction(0); } }
  else { await view.goToFraction(0); }
} catch (e) {
  if (status.hidden) say('Could not open this book.');
}
</script>
</body>
</html>''';
}
