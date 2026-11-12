# olib_api_plugin (rewrite)

Z-Library eapi client + data models for zlibx, rewritten from the
call sites in the app (inventory: `~/workspace/olib-plugin-call-inventory.md`).
It replaces the private upstream plugin, which the public repo never
shipped: `pubspec.yaml` references this package as `path: vendor/olib_api_plugin`.

Exports only what the app imports: `ZLibraryApi`, `Book`, `User`,
`ApiResponse<T>`.

> **兼容实现，与原作者无关。** Independent compatibility implementation,
> not affiliated with or endorsed by the original Olib author, and not the
> official plugin. Written from the public app's call sites only; it
> contains no code from the private upstream plugin, which was never
> published.

## Interface contract (from call sites, verified by grep)

- `ZLibraryApi()` — no-arg constructor; default domain `bookroom.lifestyle`
  (the app's `defaultDomain`). `setDomain(String)` switches the mirror.
- Auth: `login(email, password)`, `loginWithToken(userId, userKey)`,
  `sendCode(email, password, name)`, `verifyCode(email, password, name, code)`,
  `getProfile()`. Session = `remix_userid` / `remix_userkey` cookies.
- Search: `search({message, yearFrom, yearTo, languages, extensions,
  order, page, limit})` — POST form, repeated keys for list values.
  `ApiResponse.meta['total_pages']` drives pagination.
- Lists: `getBookInfo(bookId, hashId, {title})` (with `title`, an
  `Invalid hash` failure resolves the real eapi hash via a title
  search matched by id and retries once), `getMostPopular()`,
  `getUserRecommended()`, `getRecently()`, `getUserSaved({page, limit})`,
  `getUserDownloaded({page, limit})`, `getUserDownloadHistoryPage({page})` (site `/users/downloads` HTML),
  `saveBook(bookId)`, `unsaveUserBook(bookId)`,
  `similar(bookId, hashId)`.
- Download: `downloadBook(bookId, hash, savePath, {onProgress, cancelToken, title})`
  — Dio `CancelToken`, `(received, total)` progress, throws on failure.
- Error contract: `error == 'cf_blocked'` for Cloudflare walls, and
  timeout/socket/connection substrings for transient failures — the app's
  auth code branches on exactly those strings.

## Endpoint verification status

| Method | Endpoint used | Status |
|---|---|---|
| login | POST `/eapi/user/login` (+ website-login fields; falls back to POST `/rpc.php` on the same mirror if eapi login fails) | Eapi shape confirmed by independent public eapi clients (incl. heartleo/zlib, email+password only); the extra fields + rpc fallback were added 2026-11-05 after the app's community mirrors answered email+password-only with HTTP 400 on every line while the original app logs in — NOT yet live-verified |
| loginWithToken / getProfile | GET `/eapi/user/profile` | Confirmed (also named in the app's own auth comment) |
| search | POST `/eapi/book/search` | Confirmed, same parameter names |
| getBookInfo | GET `/eapi/book/{id}/{hash}` | Confirmed; a webpage short hash is rejected with `Invalid hash` — with `title` the call resolves the real hash via a title search (matched by id) and retries once |
| downloadBook | GET `/eapi/book/{id}/{hash}/file` then stream the returned link | Confirmed; same `Invalid hash` fallback as `getBookInfo` when `title` is given |
| getUserSaved | GET `/eapi/user/book/saved` | Confirmed |
| unsaveUserBook | GET `/eapi/user/book/{id}/unsave` | Confirmed |
| getUserDownloaded | GET `/eapi/user/book/downloaded` (`page`, `limit`) | Confirmed; `page`/`limit` pagination verified against the working heartleo/zlib client. NOT the site's download history: records from other devices / the website are absent from this list (2026-11-12 user report) — used only as a metadata overlay (author/cover/extension/size) for the history screen |
| getUserDownloadHistoryPage | GET `/users/downloads?page=N` (site-frontend HTML, logged-in session) — one `tr.dstats-row` per download event (`data-item_id` = book id, `/book/{shortHash}/…` link, `dd.mm.yyyy`+`HH:MM` stamp), 50 rows/page | Shape confirmed from a saved `下载历史` page (zh.z-library.sk, 2026-11-12, 50 rows on page 1); the page's own JS does no AJAX. This is the account-wide per-download log the website shows |
| saveBook | GET `/eapi/user/book/{id}/save` | Inferred by symmetry with unsave |
| getMostPopular | GET `/eapi/book/most_popular`, fallback search `order=popular` on 404 | Inferred, fallback included |
| getUserRecommended | GET `/eapi/user/recommended`, fallback most-popular on 404 | Inferred, fallback included |
| getRecently | GET `/eapi/book/recently`, fallback search `order=newest` on 404 | Inferred, fallback included |
| similar | GET `/eapi/book/{id}/{hash}/similar`, fallback title search on 404 | Inferred, fallback included |
| getBookComments | GET `/papi/comments/book/{id}/{page}?limit={limit}` | Confirmed by packet capture 2026-11-06 (zh.z-library.sk book page) — NOT eapi, site frontend JSON API; needs logged-in session |
| postBookComment | POST `/papi/comments/add`, JSON body `{hash:"", object:"book", object_id:"<id>", text, parent_id?}` as `text/plain`; first request 307s to the same URL, follow-up 200 returns the new comment | Confirmed by packet capture 2026-11-06 — top-level post, reply (`parent_id` = parent comment id, string), and response shape all captured |
| likeBookComment | POST `/papi/comments/like/{commentId}/{1\|0}`, empty JSON body as `text/plain`; 200 returns `likes` + `isLiked` arrays with the new count/state | Confirmed by packet capture 2026-11-06 — URL, 307 hop, and response shape captured |
| getMyComments | GET `/papi/comments/user/{userId}/{page}?limit={limit}` (limit 500) | Confirmed by packet capture 2026-11-06 (zh.z-library.sk profile Comments tab) — `comments` is a MAP keyed by comment id (not a list), `commentsTitles: {book: {...}}` gives each comment's book title, plus `reactionsInfo`/`reactionsUsers` |
| searchPublicBooklists / searchMyBooklists | GET `/booklists?searchQuery={q}&order={order}&page={n}` and `/booklists/my?searchQuery={q}&page={n}` (HTML, `<z-booklist>` elements) | Shape from the public sertraline/zlibrary client (read as reference only, no code copied) — NOT yet live-verified; list HTML may drift. Each list also carries its carousel books as `Booklist.previewBooks` (`<z-cover>` id/title/author/cover + hash from the wrapping link — verified from the live `/booklists/my` HTML 2026-11-06) |
| getBooklistBooks | GET `/papi/booklist/{id}/get-books/{page}` (JSON `{books: [{book: {...}}], pagination: {total_pages}}`) — `{id}` is the NUMERIC list id; pages start at 2, page 1 is server-rendered (see `getBooklistDetailBooks`) | URL + page-2+ start confirmed from the site's own `loadMoreBooks` JS, captured 2026-11-07; page 1 via this endpoint answers "Requested page not found" (device-verified 2026-11-07) |
| getBooklistDetailBooks | GET the list detail page (`/booklist/{id}/{hash}/{slug}.html`, HTML) and parse its `<z-bookcard>` elements — the first page of books | Shape confirmed from the live detail document 2026-11-07 |
| setWallCookies | No request — the app hands the plugin wall-clearance cookies (`__diamwall`, `cf_clearance`, ...) the WebView earned by passing a browser check; they ride in the `Cookie` header on mirror requests so later HTML loads skip the solver (same header, so the download path's cross-host Cookie strip covers them too) | Mechanism from the WebView's own CookieManager; the wall skipping Dio after a bridge is to be verified on device |
| createBooklist | POST `/papi/booklist/create`, JSON body `{title, description}` as `text/plain` | URL + request body confirmed by a Firefox capture 2026-11-07 (zh.z-library.sk); HTTP method assumed POST; the capture showed NO response data, so a 2xx with an empty body counts as success and callers reload the list |
| sendCode / verifyCode | POST `/eapi/user/send_code`, `/eapi/user/verify_code` | Inferred, no fallback — registration is the least certain flow |

## What is NOT verified

No Flutter/Dart toolchain exists on this machine, and no Z-Library
account was used, so this package was written without being compiled,
analyzed, or run against a live mirror. It has since been compiled by CI
and exercised on device for the main flows (login, search, book detail);
the inferred rows above stay as marked until each is individually
confirmed. In particular:

- The inferred endpoints above may 404 or return a different JSON shape;
  the parsers accept camelCase/snake_case variants and several quota
  spellings to absorb shape differences, but they cannot invent an
  endpoint that does not exist.
- Cloudflare/DiamWall walls on some mirrors will still surface as
  `cf_blocked` (the app already handles that as "line unavailable").
- Response shapes for `Book` (cover URL form, `filesizeString`,
  `interestScore`) are best-effort mappings. `User.downloadsLeft` is
  `downloads_limit - downloads_today` from `/eapi/user/profile`
  (fallbacks `dailyDownloadLimit` / `dailyDownloadsCount`,
  `downloads_left`, a `limits` object); it is `null` when the payload
  carries no quota fields, and `null` must never be read as "exhausted"
  — a 0 default once made the app show the quota dialog before any
  download was even attempted (2026-11-05 device report).
- Download links: an absolute link from the `/file` response must be
  `https`; the session Cookie is sent only to the API's own domain
  (cross-domain links and redirect hops are fetched without it), and
  redirects are followed manually (max 5 hops) for the same reason.

The first live check (login → search → book info) has since passed on
device (2026-11-05); the remaining inferred rows are promoted only by
individual confirmation.

## Publishing note

`vendor/olib_api_plugin/` is tracked in this repo (the `vendor/` ignore
was removed when the rewrite landed). Interface shapes were cross-checked
against public third-party clients, including heartleo/zlib (MIT) — no
code, structure, or comments were taken from them; only the endpoint and
payload shapes were confirmed.
