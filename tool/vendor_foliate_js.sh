#!/usr/bin/env bash
# Vendor the 13 foliate-js files the web reader needs into
# assets/web-reader/ at the pinned commit. See assets/web-reader/VENDORED.md.
#
# Needs network access (curl). Run from the repo root:
#   bash tool/vendor_foliate_js.sh
set -euo pipefail

COMMIT=78914aef4466eb960965702401634c2cb348e9b1
BASE="https://raw.githubusercontent.com/johnfactotum/foliate-js/${COMMIT}"
DEST="assets/web-reader"

FILES=(
  view.js epubcfi.js progress.js overlayer.js text-walker.js
  epub.js mobi.js fb2.js comic-book.js
  paginator.js fixed-layout.js
  vendor/zip.js vendor/fflate.js
)

mkdir -p "${DEST}/vendor"
for f in "${FILES[@]}"; do
  echo "fetching ${f}"
  curl -fsSL "${BASE}/${f}" -o "${DEST}/${f}"
done
echo "fetching LICENSE"
curl -fsSL "${BASE}/LICENSE" -o "${DEST}/LICENSE"
echo "done: ${#FILES[@]} files + LICENSE in ${DEST}/"
