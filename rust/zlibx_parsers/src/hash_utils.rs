//! Hash helpers (P0-2) — MD5 hex digest over raw bytes.
//!
//! Scope note: the only md5-adjacent Dart code in the app is
//! `externalBookId` (`lib/services/external_download.dart`), which folds
//! an *already-known* md5 string into a stable int. That is an O(8) pure
//! computation; routing it through the async FRB pool would be slower, not
//! faster, so it deliberately stays in Dart.
//!
//! What this module *does* accelerate is hashing real file bytes — the
//! kind of work a future integrity check or Anna's-Archive donation-key
//! verification needs, where Dart's `crypto` runs on the UI isolate and
//! blocks frames. The Rust path hashes off-thread via the FRB pool.
//!
//! # ⚠️ Security notice
//!
//! MD5 is **NOT collision-resistant**. Do NOT use `md5_hex` for
//! security-critical verification (e.g. signature checking, password
//! hashing, tamper detection). Use SHA-256+ for those purposes. This
//! function is suitable only for non-adversarial checksums (cache keys,
//! deduplication, legacy protocol compatibility).

use md5::{Digest, Md5};

/// Lowercase hex MD5 of the given bytes.
///
/// See the module-level security notice before using this for any
/// security-sensitive purpose.
pub(crate) fn md5_hex(bytes: &[u8]) -> String {
    let mut hasher = Md5::new();
    hasher.update(bytes);
    hex::encode(hasher.finalize())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_known_vectors() {
        assert_eq!(md5_hex(b""), "d41d8cd98f00b204e9800998ecf8427e");
        assert_eq!(md5_hex(b"abc"), "900150983cd24fb0d6963f7d28e17f72");
        assert_eq!(
            md5_hex(b"The quick brown fox jumps over the lazy dog"),
            "9e107d9d372bb6826bd81d3542a419d6"
        );
    }

    #[test]
    fn handles_multibyte_input() {
        // Non-empty, deterministic, 32 lowercase hex chars.
        let h = md5_hex("中文书名".as_bytes());
        assert_eq!(h.len(), 32);
        assert!(h.chars().all(|c| c.is_ascii_hexdigit()));
    }
}
