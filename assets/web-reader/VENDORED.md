# Vendored foliate-js (web reader)

The LAN web service's reader page (`/read/<index>`) renders books in the
user's browser with [foliate-js](https://github.com/johnfactotum/foliate-js).
The files in this directory are served by `WebService` under
`/reader-assets/<file>`.

## Source

- Upstream: https://github.com/johnfactotum/foliate-js
- Pinned commit: `78914aef4466eb960965702401634c2cb348e9b1` (2026-05-01)
- License: MIT — `LICENSE` from the same commit must sit in this directory.
- Upstream has no release versions; the commit hash is the version.

## Status of this checkout

The 13 files below **are** vendored in this directory (plus `LICENSE`).
Re-fetch them only when upgrading to a newer upstream commit:

```bash
bash tool/vendor_foliate_js.sh
```

(downloads and the home page are unaffected by the reader files; if
they were missing, the reader page would show "Reader library is not
installed" and every `/reader-assets/*` request would answer 404).

## Files (13) — also the server-side whitelist

| File | Role |
|---|---|
| `view.js` | entry point (`<foliate-view>`) |
| `epubcfi.js`, `progress.js`, `overlayer.js`, `text-walker.js` | static dependencies of `view.js` |
| `epub.js`, `mobi.js`, `fb2.js`, `comic-book.js` | format parsers, loaded on demand |
| `paginator.js`, `fixed-layout.js` | reflowable / fixed-layout rendering |
| `vendor/zip.js`, `vendor/fflate.js` | zip + inflate |

`kReaderAssetWhitelist` in `lib/services/web_service.dart` lists exactly
these paths; anything else under `/reader-assets/` is a 404.

## Deliberately NOT vendored

`pdf.js` and `vendor/pdfjs/` (PDF reading is out of scope), `search.js`,
`tts.js`, `dict.js`, `opds.js`, `quote-image.js`, `footnotes.js`, and the
upstream demo reader (`reader.js`, `reader.html`, `ui/`). The reader UI is
our own (`lib/services/web_reader_page.dart`).

## Upgrading

Re-fetch the same 13 files + `LICENSE` from the new upstream commit
(edit `COMMIT` in `tool/vendor_foliate_js.sh`), update the commit and date
above, and re-test EPUB / MOBI / AZW3 / FB2 / CBZ / TXT on a real device.
If upstream adds a static import to `view.js`, add the file here **and** to
`kReaderAssetWhitelist`.

## Known limitations (accepted)

- **Embedded font decryption needs Web Crypto, which browsers only expose in
  a secure context.** The LAN service is plain HTTP, so EPUBs with obfuscated
  embedded fonts fall back to system fonts. Rare.
- **MOBI / AZW3 / FB2 / CBZ progress is only accurate to the chapter.**
- **Progress and settings live in the browser's `localStorage`** — a
  different browser or cleared site data starts over. There is no
  server-side progress sync.
- PDF books are download-only (no "Read" link); DRM-protected books cannot
  be read by any approach.
