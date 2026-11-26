// Shared by the web service (/read, /book) and the in-app local
// reader: which formats foliate-js can open, and which asset files
// the reader page may load. One copy so the two readers never drift
// apart (a format added here works in both).

/// The only files the reader page will ever load (the 13 vendored
/// foliate-js files). Anything else is a 404.
const Set<String> kReaderAssetWhitelist = <String>{
  'view.js',
  'epubcfi.js',
  'progress.js',
  'overlayer.js',
  'text-walker.js',
  'epub.js',
  'mobi.js',
  'fb2.js',
  'comic-book.js',
  'paginator.js',
  'fixed-layout.js',
  'vendor/zip.js',
  'vendor/fflate.js',
};

/// Formats the reader can open. PDF is not opened by the reader —
/// a desktop browser renders it with its own PDF viewer through
/// /book instead (see [isPdfExtension]); in the app a PDF opens in
/// the external viewer. DRM is not handled at all.
const Set<String> kReadableExtensions = <String>{
  'epub',
  'mobi',
  'azw3',
  'fb2',
  'cbz',
  'txt',
};

bool isReadableExtension(String? extension) =>
    kReadableExtensions.contains((extension ?? '').toLowerCase());

/// A PDF is viewable in the browser itself: /book serves it inline
/// (no Content-Disposition: attachment), so Chrome / Edge / Firefox
/// open it in their built-in PDF viewer. The foliate reader cannot
/// open PDFs, so /read still refuses them.
bool isPdfExtension(String? extension) =>
    (extension ?? '').toLowerCase() == 'pdf';
