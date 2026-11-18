import 'dart:convert';
import 'dart:io';

import 'package:android_intent_plus/android_intent.dart';
import 'package:zlibx/utils/diagnostics.dart';

import '../services/media_store.dart';
import 'app_log.dart';


/// Check if platform supports opening folder in file manager
/// (Android-only build: always true on Android.)
bool get canOpenFolder => Platform.isAndroid;

/// Open the download folder in the system file manager
Future<bool> openDownloadFolder() async {
  try {
    if (Platform.isAndroid) {
      // Use Intent to open the Downloads folder in the system file manager
      try {
        final intent = AndroidIntent(
          action: 'android.intent.action.VIEW',
          data:
              'content://com.android.externalstorage.documents/document/primary%3ADownload%2Fzlibx',
          type: 'vnd.android.document/directory',
          flags: <int>[0x10000000], // FLAG_ACTIVITY_NEW_TASK
        );
        await intent.launch();
        return true;
      } catch (error) {
        logIgnored('file_utils', error);
        // Fallback: try to open the general Downloads folder
        try {
          final intent = AndroidIntent(
            action: 'android.intent.action.VIEW',
            data:
                'content://com.android.externalstorage.documents/root/primary%3ADownload',
            type: 'vnd.android.document/root',
            flags: <int>[0x10000000],
          );
          await intent.launch();
          return true;
        } catch (error) {
          logIgnored('file_utils', error);
          // Last fallback: open the system file manager app
          try {
            final intent = AndroidIntent(
              action: 'android.intent.action.MAIN',
              category: 'android.intent.category.APP_FILES',
              flags: <int>[0x10000000],
            );
            await intent.launch();
            return true;
          } catch (error) {
            logIgnored('file_utils', error);
            return false;
          }
        }
      }
    }
    return false;
  } catch (e) {
    AppLog.report('Failed to open download folder: $e', tag: 'file_utils');
    return false;
  }
}

/// Open a file with the system default application.
/// Understands both plain paths and the content:// URIs of
/// MediaStore-published downloads.
Future<bool> openFile(String filePath) async {
  try {
    if (!await MediaStoreFiles.exists(filePath)) {
      return false;
    }
    return await MediaStoreFiles.open(filePath);
  } catch (e) {
    AppLog.report('Failed to open file: $e', tag: 'file_utils');
    return false;
  }
}

/// Android caps a single filename at 255 bytes (UTF-8). Keep our
/// generated names comfortably below that so a long (e.g. Chinese)
/// title can never fail the write. The cap counts the whole
/// `name.extension` filename, not just the title part.
const int maxFileNameBytes = 200;

/// Truncate [input] so its UTF-8 byte length is at most [maxBytes],
/// cutting only on rune boundaries so a multi-byte character is
/// never split in half. Returns [input] unchanged when it fits.
String truncateUtf8ByBytes(String input, int maxBytes) {
  if (utf8.encode(input).length <= maxBytes) return input;
  var bytes = 0;
  var end = 0; // UTF-16 code-unit index into [input]
  for (final rune in input.runes) {
    final runeBytes = rune < 0x80
        ? 1
        : rune < 0x800
        ? 2
        : rune < 0x10000
        ? 3
        : 4;
    if (bytes + runeBytes > maxBytes) break;
    bytes += runeBytes;
    end += rune > 0xFFFF ? 2 : 1;
  }
  return input.substring(0, end);
}
