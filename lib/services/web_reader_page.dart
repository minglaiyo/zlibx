// The web reader's host page (served at /read/<bookId>).
//
// Runs in the user's own desktop browser, so JavaScript is fine here
// (unlike the plain-HTML home page). It loads the vendored foliate-js
// `view.js` from /reader-assets/, downloads the book bytes from
// /book/<bookId>, and provides the UI: table-of-contents sidebar, prev /
// next paging with arrow keys, saved position, font size and a
// light / dark theme. Position and settings live in the browser's
// localStorage, keyed per book.
import 'dart:convert';

/// Minimal HTML escaping for text placed in element content / attributes.
String escapeHtml(String s) =>
    const HtmlEscape(HtmlEscapeMode.attribute).convert(s);

/// JSON string literal that is safe inside an inline <script>.
String _jsString(String s) => jsonEncode(s)
    .replaceAll('&', r'\u0026')
    .replaceAll('<', r'\u003c')
    .replaceAll('>', r'\u003e')
    .replaceAll('\u2028', r'\u2028')
    .replaceAll('\u2029', r'\u2029');

/// Add the access token without allowing it to alter the query string.
String _withToken(String path, String token) =>
    '$path?t=${Uri.encodeQueryComponent(token)}';

/// Build the reader page for the book at snapshot [bookId].
///
/// [bookKey] identifies the book for the saved position (stable across
/// service restarts: it is derived from the book's own identity, not
/// from [bookId], which only lives for one snapshot).
///
/// [accessToken] is embedded only as escaped HTML/JS and is never logged.
String buildReaderPage({
  required int bookId,
  required String title,
  required String bookKey,
  required String accessToken,
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
  [hidden] { display: none !important; }
  html, body { height: 100%; margin: 0; background: var(--bg); color: var(--fg);
    font-family: system-ui, -apple-system, "Segoe UI", "PingFang SC", "Microsoft YaHei", sans-serif; }
  #app { display: flex; flex-direction: column; height: 100%; }
  #bar { display: flex; align-items: center; gap: 8px; padding: 6px 10px;
    background: var(--bar); border-bottom: 1px solid var(--line); }
  #bar .title { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 14px; }
  button { min-width: 44px; min-height: 44px; background: transparent; color: var(--fg);
    border: 1px solid var(--line); border-radius: 6px; padding: 4px 10px;
    font-size: 14px; cursor: pointer; touch-action: manipulation; }
  button:hover { border-color: var(--accent); }
  button:focus-visible, a:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
  button:disabled { opacity: .5; cursor: default; }
  #main { flex: 1; display: flex; min-height: 0; }
  #toc { flex: 0 0 280px; width: 280px; overflow: auto; padding: 8px 0;
    background: var(--bar); border-right: 1px solid var(--line); }
  #toc-header { display: none; }
  #toc a { display: flex; align-items: center; min-height: 44px; padding: 6px 14px;
    color: var(--fg); text-decoration: none; font-size: 13px; line-height: 1.4; }
  #toc a:hover { background: var(--line); }
  #toc a.sub { padding-left: 28px; }
  #toc-backdrop { position: fixed; inset: 0; z-index: 20; background: rgba(0, 0, 0, .45); }
  #stage { flex: 1; min-width: 0; position: relative; }
  #status { position: absolute; inset: 0; z-index: 10; display: flex; align-items: center;
    justify-content: center; padding: 24px; text-align: center; line-height: 1.6;
    background: var(--bg); }
  #status-card { width: min(420px, 100%); padding: 24px; border: 1px solid var(--line);
    border-radius: 10px; background: var(--bar); }
  #status-text { font-size: 16px; font-weight: 600; overflow-wrap: anywhere; }
  #status[data-kind="error"] #status-card { border: 2px solid var(--accent); }
  #status[data-kind="offline"] #status-card { border: 2px solid var(--accent); }
  #status-actions { display: flex; justify-content: center; flex-wrap: wrap; gap: 10px; margin-top: 18px; }
  #download-progress { display: block; width: 100%; height: 10px; margin-top: 18px;
    accent-color: var(--accent); }
  #progress-detail { margin-top: 8px; font-size: 13px; color: var(--fg); overflow-wrap: anywhere; }
  foliate-view { display: block; width: 100%; height: 100%; }
  #foot { display: flex; align-items: center; justify-content: space-between;
    padding: 0 12px; font-size: 12px; background: var(--bar); border-top: 1px solid var(--line); }
  #home { display: inline-flex; align-items: center; justify-content: center;
    min-width: 44px; min-height: 44px; color: var(--accent); font-size: 18px; text-decoration: none; }
  @media (max-width: 720px) {
    #bar { gap: 4px; padding: 4px 6px; }
    #toc { position: fixed; inset: 0 auto 0 0; z-index: 30; width: min(280px, 85vw);
      max-width: 280px; transform: translateX(-100%); visibility: hidden;
      transition: transform .18s ease, visibility .18s ease; box-shadow: 4px 0 18px rgba(0, 0, 0, .25); }
    #toc.open { transform: translateX(0); visibility: visible; }
    #toc-header { position: sticky; top: 0; z-index: 1; display: flex; align-items: center;
      justify-content: space-between; min-height: 52px; padding: 4px 6px 4px 14px;
      background: var(--bar); border-bottom: 1px solid var(--line); font-size: 14px; font-weight: 600; }
    body.toc-open { overflow: hidden; }
  }
</style>
</head>
<body>
<div id="app">
  <div id="bar">
    <button id="btn-toc" type="button" title="目录" aria-label="目录" aria-controls="toc" aria-expanded="false">☰</button>
    <div class="title">${escapeHtml(title)}</div>
    <button id="btn-font-" type="button" title="减小字号" aria-label="减小字号">A−</button>
    <button id="btn-font+" type="button" title="增大字号" aria-label="增大字号">A+</button>
    <button id="btn-theme" type="button" title="切换主题" aria-label="切换主题">◐</button>
    <button id="btn-prev" type="button" title="上一页" aria-label="上一页">‹</button>
    <button id="btn-next" type="button" title="下一页" aria-label="下一页">›</button>
  </div>
  <div id="main">
    <nav id="toc" aria-label="目录" hidden>
      <div id="toc-header"><span>目录</span><button id="btn-toc-close" type="button" title="关闭目录" aria-label="关闭目录">×</button></div>
    </nav>
    <div id="toc-backdrop" hidden></div>
    <div id="stage">
      <div id="status" role="status" aria-live="polite" data-kind="loading">
        <div id="status-card">
          <div id="status-text">正在加载阅读器…</div>
          <progress id="download-progress" max="100" value="0" aria-label="下载进度" hidden></progress>
          <div id="progress-detail" hidden></div>
          <div id="status-actions">
            <button id="btn-retry" type="button" hidden>重新加载</button>
            <button id="btn-cancel" type="button">取消</button>
          </div>
        </div>
      </div>
    </div>
  </div>
  <div id="foot"><span id="where"></span><a id="home" href="${escapeHtml(_withToken('/', accessToken))}" title="首页" aria-label="首页">⌂</a></div>
</div>
<!-- Relative imports in foliate-js do not inherit view.js's query string. -->
<script type="importmap">
{
  "imports": {
    "/reader-assets/comic-book.js": ${_jsString(_withToken('/reader-assets/comic-book.js', accessToken))},
    "/reader-assets/epub.js": ${_jsString(_withToken('/reader-assets/epub.js', accessToken))},
    "/reader-assets/epubcfi.js": ${_jsString(_withToken('/reader-assets/epubcfi.js', accessToken))},
    "/reader-assets/fb2.js": ${_jsString(_withToken('/reader-assets/fb2.js', accessToken))},
    "/reader-assets/fixed-layout.js": ${_jsString(_withToken('/reader-assets/fixed-layout.js', accessToken))},
    "/reader-assets/mobi.js": ${_jsString(_withToken('/reader-assets/mobi.js', accessToken))},
    "/reader-assets/overlayer.js": ${_jsString(_withToken('/reader-assets/overlayer.js', accessToken))},
    "/reader-assets/paginator.js": ${_jsString(_withToken('/reader-assets/paginator.js', accessToken))},
    "/reader-assets/progress.js": ${_jsString(_withToken('/reader-assets/progress.js', accessToken))},
    "/reader-assets/text-walker.js": ${_jsString(_withToken('/reader-assets/text-walker.js', accessToken))},
    "/reader-assets/vendor/fflate.js": ${_jsString(_withToken('/reader-assets/vendor/fflate.js', accessToken))},
    "/reader-assets/vendor/zip.js": ${_jsString(_withToken('/reader-assets/vendor/zip.js', accessToken))},
    "/reader-assets/view.js": ${_jsString(_withToken('/reader-assets/view.js', accessToken))}
  }
}
</script>
<script type="module">
const ACCESS_TOKEN = ${_jsString(accessToken)};
const withToken = (path) => path + '?t=' + encodeURIComponent(ACCESS_TOKEN);
const BOOK_URL = withToken('/book/$bookId');
const BOOK_KEY = ${_jsString(bookKey)};
const POS_KEY = 'zlibx:pos:' + BOOK_KEY;
const FONT_KEY = 'zlibx:font';
const THEME_KEY = 'zlibx:theme';

// localStorage can be missing or full (private mode): never let that
// break reading.
const store = {
  get(k) { try { return localStorage.getItem(k); } catch (e) { return null; } },
  set(k, v) { try { localStorage.setItem(k, v); } catch (e) { /* noop */ } },
};

const \$ = (id) => document.getElementById(id);
const status = \$('status');
const statusText = \$('status-text');
const progress = \$('download-progress');
const progressDetail = \$('progress-detail');
const btnRetry = \$('btn-retry');
const btnCancel = \$('btn-cancel');
const toc = \$('toc');
const tocBackdrop = \$('toc-backdrop');
const btnToc = \$('btn-toc');
const btnTocClose = \$('btn-toc-close');

function setStatus(message, kind, { retry = false, cancel = false } = {}) {
  status.hidden = false;
  status.dataset.kind = kind;
  statusText.textContent = message;
  progress.hidden = true;
  progress.value = 0;
  progressDetail.hidden = true;
  progressDetail.textContent = '';
  btnRetry.hidden = !retry;
  btnRetry.disabled = false;
  btnCancel.hidden = !cancel;
  btnCancel.disabled = false;
}

function formatBytes(bytes) {
  if (bytes < 1024) return bytes + ' B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  let value = bytes / 1024;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return value.toFixed(value >= 10 ? 1 : 2) + ' ' + units[unit];
}

function updateProgress(message, loaded, total) {
  statusText.textContent = message;
  progressDetail.hidden = false;
  const loadedLabel = '已读 ' + formatBytes(loaded) + '（' + loaded.toLocaleString() + ' 字节）';
  if (total === null) {
    progress.hidden = true;
    progressDetail.textContent = loadedLabel;
    return;
  }
  progress.hidden = false;
  const percent = total > 0 ? Math.min(100, Math.floor(loaded * 100 / total)) : (loaded > 0 ? 100 : 0);
  progress.value = percent;
  progressDetail.textContent = loadedLabel + ' / ' + formatBytes(total) + ' · ' + percent + '%';
}

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
  try { view.renderer.setStyles(css); } catch (e) { /* noop */ }
}

// ── Paging ──
const prev = () => view && view.prev();
const next = () => view && view.next();
\$('btn-prev').onclick = prev;
\$('btn-next').onclick = next;

// ── Contents ──
const tocMedia = matchMedia('(max-width: 720px)');
const isNarrow = () => tocMedia.matches;
function syncToc() {
  const open = !toc.hidden;
  const drawer = open && isNarrow();
  toc.classList.toggle('open', drawer);
  tocBackdrop.hidden = !drawer;
  document.body.classList.toggle('toc-open', drawer);
  btnToc.setAttribute('aria-expanded', String(open));
}
function setToc(open, restoreFocus = false) {
  toc.hidden = !open;
  syncToc();
  if (open && isNarrow()) btnTocClose.focus({ preventScroll: true });
  else if (!open && restoreFocus) btnToc.focus({ preventScroll: true });
}
\$('btn-toc').onclick = () => setToc(toc.hidden);
\$('btn-toc-close').onclick = () => setToc(false, true);
tocBackdrop.onclick = () => setToc(false, true);
if (tocMedia.addEventListener) tocMedia.addEventListener('change', syncToc);
else tocMedia.addListener(syncToc);

const onKey = (e) => {
  if (e.key === 'Escape' && !toc.hidden) {
    e.preventDefault();
    setToc(false, true);
    return;
  }
  if (e.key === 'ArrowLeft' || e.key === 'PageUp') { e.preventDefault(); prev(); }
  else if (e.key === 'ArrowRight' || e.key === 'PageDown' || e.key === ' ') { e.preventDefault(); next(); }
};
addEventListener('keydown', onKey);

function renderToc(items, depth = 0) {
  const nav = \$('toc');
  for (const item of items || []) {
    const a = document.createElement('a');
    a.textContent = item.label || '';
    a.href = '#';
    if (depth) a.className = 'sub';
    a.onclick = (e) => {
      e.preventDefault();
      if (view) {
        try { view.goTo(item.href); } catch (error) { /* noop */ }
      }
      if (isNarrow()) setToc(false, true);
    };
    nav.appendChild(a);
    if (item.subitems) renderToc(item.subitems, depth + 1);
  }
}

// ── Loading, cancellation and retry ──
class ReaderLoadError extends Error {
  constructor(kind, status = null) {
    super(kind);
    this.kind = kind;
    this.status = status;
  }
}

let phase = 'idle';
let disposed = false;
let suspended = false;
let loadVersion = 0;
let activeController = null;
let activeReader = null;
let activeAbortReason = null;

const isActive = (version, controller) =>
  !disposed && loadVersion === version && activeController === controller && !controller.signal.aborted;

function disposeView(target = view) {
  if (!target) return;
  if (view === target) view = null;
  try {
    if (typeof target.close === 'function') target.close();
    else if (typeof target.destroy === 'function') target.destroy();
    else if (target.renderer && typeof target.renderer.destroy === 'function') target.renderer.destroy();
  } catch (e) {
    try {
      if (typeof target.destroy === 'function') target.destroy();
    } catch (error) { /* noop */ }
  }
  try { target.remove(); } catch (e) { /* noop */ }
  // Do not keep the parsed book, renderer or File alive after closing it.
  try { target.book = null; } catch (e) { /* noop */ }
  try { target.renderer = null; } catch (e) { /* noop */ }
}

function releaseReader(reader) {
  if (!reader) return;
  if (activeReader === reader) activeReader = null;
  try { reader.releaseLock(); } catch (e) { /* noop */ }
}

function cancelReader(reader) {
  if (!reader) return;
  if (activeReader === reader) activeReader = null;
  try { Promise.resolve(reader.cancel()).catch(() => {}); } catch (e) { /* noop */ }
}

function showCancelled() {
  phase = 'cancelled';
  setStatus('已取消加载。', 'cancelled', { retry: true });
}

function showOffline() {
  phase = 'offline';
  setStatus('当前离线，请检查网络连接后重试。', 'offline', { retry: true });
}

function showFailure(error) {
  // Never display or log caught errors: fetch/import errors may contain
  // URLs, including the access token.
  let message = '书籍加载失败，请重试。';
  let kind = 'error';
  if (error && error.kind === 'offline') {
    message = '当前离线，请检查网络连接后重试。';
    kind = 'offline';
  } else if (error && error.kind === 'reader') {
    message = '阅读器组件加载失败，请重试。';
  } else if (error && error.kind === 'http') {
    if (error.status === 401 || error.status === 403) {
      message = '访问已失效（HTTP ' + error.status + '），请返回首页重新打开。';
    } else {
      message = '书籍加载失败（HTTP ' + error.status + '），请重试。';
    }
  } else if (error && error.kind === 'body') {
    message = '当前浏览器无法读取下载内容，请更新浏览器后重试。';
  } else if (error && error.kind === 'incomplete') {
    message = '下载未完成，请重试。';
  }
  phase = kind === 'offline' ? 'offline' : 'failed';
  setStatus(message, kind, { retry: true });
}

function cancelLoad() {
  if (phase !== 'loading') return;
  activeAbortReason = 'cancelled';
  if (activeController && !activeController.signal.aborted) activeController.abort();
  cancelReader(activeReader);
  disposeView();
  showCancelled();
}

function networkChanged() {
  if (navigator.onLine) {
    if (phase === 'offline') setStatus('网络已恢复，可以重试。', 'offline', { retry: true });
    return;
  }
  if (phase === 'loading') {
    activeAbortReason = 'offline';
    if (activeController && !activeController.signal.aborted) activeController.abort();
    cancelReader(activeReader);
    showOffline();
  } else if (phase === 'failed' || phase === 'cancelled') {
    showOffline();
  }
}
addEventListener('offline', networkChanged);
addEventListener('online', networkChanged);

async function loadBook() {
  const version = ++loadVersion;
  if (activeController && !activeController.signal.aborted) activeController.abort();
  cancelReader(activeReader);
  disposeView();
  setToc(false);

  const controller = new AbortController();
  activeController = controller;
  activeAbortReason = null;
  phase = 'loading';
  setStatus('正在加载阅读器…', 'loading', { cancel: true });

  let reader = null;
  let readerView = null;
  let chunks = null;
  let blob = null;
  let file = null;
  let completed = false;
  try {
    if (!navigator.onLine) throw new ReaderLoadError('offline');
    try {
      await import(withToken('/reader-assets/view.js'));
    } catch (e) {
      if (!isActive(version, controller)) return;
      throw new ReaderLoadError('reader');
    }
    if (!isActive(version, controller)) return;
    if (!navigator.onLine) throw new ReaderLoadError('offline');

    updateProgress('正在下载书籍…', 0, null);
    const resp = await fetch(BOOK_URL, { signal: controller.signal, cache: 'no-store' });
    if (!isActive(version, controller)) {
      try { await resp.body?.cancel(); } catch (e) { /* noop */ }
      return;
    }
    if (!resp.ok) throw new ReaderLoadError('http', resp.status);
    if (!resp.body) throw new ReaderLoadError('body');

    const lengthHeader = resp.headers.get('Content-Length');
    const parsedLength = lengthHeader === null ? NaN : Number(lengthHeader);
    const total = lengthHeader !== null && lengthHeader.trim() !== '' &&
      Number.isSafeInteger(parsedLength) && parsedLength >= 0 ? parsedLength : null;

    // Read the response incrementally for progress/cancellation, but keep
    // the existing Blob -> File flow required by foliate-js. The chunks
    // are released as soon as the Blob has been assembled.
    chunks = [];
    reader = resp.body.getReader();
    activeReader = reader;
    let loaded = 0;
    updateProgress('正在下载书籍…', loaded, total);
    while (true) {
      const { done, value } = await reader.read();
      if (!isActive(version, controller)) return;
      if (done) break;
      chunks.push(value);
      loaded += value.byteLength;
      updateProgress('正在下载书籍…', loaded, total);
    }
    if (total !== null && loaded !== total) throw new ReaderLoadError('incomplete');
    releaseReader(reader);
    reader = null;

    if (total !== null) updateProgress('下载完成', loaded, total);
    blob = new Blob(chunks, { type: resp.headers.get('Content-Type') || '' });
    chunks.length = 0;
    chunks = null;
    const name = resp.headers.get('X-Book-Name') || 'book';
    file = new File([blob], name, { type: blob.type });
    blob = null;

    setStatus('正在打开书籍…', 'loading', { cancel: true });
    readerView = document.createElement('foliate-view');
    view = readerView;
    \$('stage').appendChild(readerView);
    readerView.addEventListener('relocate', (e) => {
      const d = e.detail || {};
      if (d.cfi) store.set(POS_KEY, d.cfi);
      if (typeof d.fraction === 'number') \$('where').textContent = Math.round(d.fraction * 100) + '%';
    });
    readerView.addEventListener('load', (e) => {
      // Arrow keys must also work while focus is inside the book iframe.
      const doc = e.detail && e.detail.doc;
      if (doc) doc.addEventListener('keydown', onKey);
    });

    await readerView.open(file);
    file = null;
    if (!isActive(version, controller)) return;

    for (const link of toc.querySelectorAll('a')) link.remove();
    renderToc(readerView.book && readerView.book.toc);
    applyTheme();
    const saved = store.get(POS_KEY);
    if (saved) {
      try { await readerView.goTo(saved); } catch (e) { await readerView.goToFraction(0); }
    } else {
      await readerView.goToFraction(0);
    }
    if (!isActive(version, controller)) return;

    completed = true;
    phase = 'ready';
    status.hidden = true;
  } catch (e) {
    if (disposed || loadVersion !== version) return;
    if (controller.signal.aborted) {
      if (activeAbortReason === 'offline') showOffline();
      else showCancelled();
    } else {
      showFailure(e);
    }
  } finally {
    if (chunks) chunks.length = 0;
    chunks = null;
    blob = null;
    file = null;
    releaseReader(reader);
    if (activeController === controller) activeController = null;
    if (readerView && !completed) disposeView(readerView);
  }
}

btnRetry.onclick = loadBook;
btnCancel.onclick = cancelLoad;

function shutdown(event) {
  const cached = event && event.type === 'pagehide' && event.persisted;
  disposed = true;
  loadVersion++;
  if (activeController && !activeController.signal.aborted) activeController.abort();
  cancelReader(activeReader);
  activeController = null;
  activeReader = null;
  disposeView();
  setToc(false);
  if (cached) suspended = true;
}
addEventListener('beforeunload', shutdown);
addEventListener('pagehide', shutdown);
addEventListener('pageshow', (event) => {
  if (!event.persisted || !suspended) return;
  suspended = false;
  disposed = false;
  loadBook();
});

await loadBook();
</script>
</body>
</html>''';
}
