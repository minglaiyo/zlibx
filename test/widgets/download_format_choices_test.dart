import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/screens/book_detail/widgets/download_format_dialog.dart';

// downloadFormatChoices tests (plan item 2): the picker menu always
// offers the format already on the detail page, first when the server
// list does not carry it, never duplicated when it does.

void main() {
  const book = Book(
    id: 123,
    title: 'Test Book',
    hash: 'abc123',
    extension: 'EPUB',
    filesize: 100,
    filesizeString: '100 B',
  );

  test('current format is prepended when the server list lacks it', () {
    final choices = downloadFormatChoices(
      book: book,
      formats: const [
        BookFormat(id: 456, hash: 'def456', extension: 'pdf'),
        BookFormat(id: 789, hash: 'ghi789', extension: 'mobi'),
      ],
    );
    expect(choices.length, 3);
    expect(choices[0].id, 123);
    expect(choices[0].hash, 'abc123');
    expect(choices[0].extension, 'epub');
    expect(choices[0].filesizeString, '100 B');
    // Server order is kept after the prepended entry.
    expect(choices[1].extension, 'pdf');
    expect(choices[2].extension, 'mobi');
  });

  test('current format is not duplicated when the server lists it', () {
    const server = [
      BookFormat(id: 456, hash: 'def456', extension: 'pdf'),
      BookFormat(id: 123, hash: 'abc123', extension: 'epub'),
    ];
    final choices = downloadFormatChoices(book: book, formats: server);
    expect(choices.length, 2);
    expect(choices, server);
  });

  test('an empty server list leaves just the current format', () {
    final choices = downloadFormatChoices(book: book, formats: const []);
    expect(choices.length, 1);
    expect(choices[0].id, 123);
    expect(choices[0].extension, 'epub');
  });
}
