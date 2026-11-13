/// Explicit allow-list of Z-Library site suffixes. A host belongs to the
/// family only when it is one of these suffixes or a subdomain of one,
/// e.g. `z-library.sk`, `reader.z-lib.fm`, `bookroom.lifestyle`.
/// Anything else is not family — including a look-alike registrable
/// domain whose label matches, such as `z-lib.xyz` or `z-library.top`.
/// The old rule only checked the label right before the TLD, so any
/// TLD (or subdomain prefix) paired with a family label passed; the
/// `singlelogin.*` domains are deliberately absent — `singlelogin.se`
/// is parked for sale, `singlelogin.re` and `1lib.singlelogin.se` do not
/// resolve (checked 2026-11-11).
const _zlibFamilySuffixes = {
  'z-library.sk',
  'z-library.im',
  'z-library.mn',
  'z-lib.fm',
  'z-lib.gd',
  'bookroom.lifestyle',
};

/// Whether [rawHost] is a Z-Library family host.
///
/// This replaces a loose label check, which accepted any host whose
/// label before the TLD was `z-library`, `z-lib`, `bookroom` or
/// `singlelogin` — including look-alike hosts such as `z-lib.xyz`.
/// Only an explicit suffix (or its subdomain) counts.
bool isZlibFamilyHost(String rawHost) {
  final host = rawHost.trim().toLowerCase();
  if (host.isEmpty || host.contains(':') || host.contains('/')) return false;
  final labels = host.split('.');
  if (labels.length < 2 || labels.any((l) => l.isEmpty)) return false;
  return _zlibFamilySuffixes.any(
    (suffix) => host == suffix || host.endsWith('.$suffix'),
  );
}

/// Explicit allow-list of Anna's Archive SEARCH hosts. Only these hosts
/// ever receive the user's donation key (see
/// `AnnasArchieve.getFastDownloadUrl`).
///
/// Ground truth (checked 2026-11-13, open-slum.org/annas.html): the
/// live search mirrors are `annas-archive.gl`, `annas-archive.pk` and
/// `annas-archive.gd`; `annas-archive.org` is the canonical domain.
/// The download servers `yqrii5.org` / `wbsg8v.xyz` are NOT search
/// hosts and are not here.
///
/// Exact-host match only — deliberately NO subdomain wildcard, unlike
/// [isZlibFamilyHost]: `software.annas-archive.gl` is a GitLab instance
/// on the same annas page, not a search host, and must never receive
/// the key. If Anna adds a new official search domain, add it here
/// explicitly; an unlisted host fails closed (fast download returns
/// null and the caller falls back to slow download).
const _annasFamilyHosts = {
  'annas-archive.org',
  'annas-archive.gl',
  'annas-archive.pk',
  'annas-archive.gd',
};

/// Whether [rawHost] is an Anna's Archive search host that may receive
/// the user's donation key. Exact-host match only (see [_annasFamilyHosts]).
bool isAnnasFamilyHost(String rawHost) {
  final host = rawHost.trim().toLowerCase();
  if (host.isEmpty || host.contains(':') || host.contains('/')) return false;
  return _annasFamilyHosts.contains(host);
}

/// Language prefixes some mirrors put in front of the domain
/// (`zh.z-lib.fm`); the reader never lives under them.
const _readerLangPrefixes = {
  'zh', 'en', 'de', 'fr', 'es', 'it', 'pt', 'ja', 'ko', 'ru', 'ar',
};

/// Reader host for the current line [lineDomain]:
/// `z-lib.fm` -> `reader.z-lib.fm`, `zh.z-lib.fm` -> `reader.z-lib.fm`.
String readerDomainFor(String lineDomain) {
  final dot = lineDomain.indexOf('.');
  if (dot > 0 && _readerLangPrefixes.contains(lineDomain.substring(0, dot))) {
    return 'reader${lineDomain.substring(dot)}';
  }
  return 'reader.$lineDomain';
}

/// Whether [url] is a reader page of the current line [lineDomain]: https,
/// no userinfo, and a host that is the line's reader host or inside the
/// line's own domain.
///
/// `Book.readOnlineUrl` comes from the server response, so it must never
/// decide where the session cookies (`remix_userkey`) get written: a
/// mirror (or a tampered response) could name any host there.
bool isTrustedReaderUrl(String url, String lineDomain) {
  // A custom line may carry a port (`host:8443`); Uri.host never does.
  final line = lineDomain.trim().toLowerCase().split(':').first;
  if (line.isEmpty) return false;
  final uri = Uri.tryParse(url);
  if (uri == null || uri.scheme != 'https' || uri.userInfo.isNotEmpty) {
    return false;
  }
  final host = uri.host.toLowerCase();
  if (host.isEmpty) return false;
  final reader = readerDomainFor(line);
  final bare = reader.substring('reader.'.length);
  return host == reader ||
      host == bare ||
      host.endsWith('.$bare') ||
      host == line ||
      host.endsWith('.$line');
}
