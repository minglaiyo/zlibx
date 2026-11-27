import 'package:flutter_test/flutter_test.dart';
import 'package:zlibx/services/download_target.dart';

void main() {
  test('primary URL stays first and duplicate fallbacks are removed', () {
    final target = chooseDownloadTarget(
      url: ' https://primary.example/book.epub ',
      fallbackUrls: const [
        'https://primary.example/book.epub',
        ' https://mirror-a.example/book.epub ',
        '',
        'https://mirror-a.example/book.epub',
        'https://mirror-b.example/book.epub',
      ],
      fast: false,
    );

    expect(target.url, 'https://primary.example/book.epub');
    expect(target.fallbackUrls, [
      'https://mirror-a.example/book.epub',
      'https://mirror-b.example/book.epub',
    ]);
    expect(target.candidateUrls, [
      'https://primary.example/book.epub',
      'https://mirror-a.example/book.epub',
      'https://mirror-b.example/book.epub',
    ]);
  });

  test('a fallback can become primary when the first URL is empty', () {
    final target = chooseDownloadTarget(
      url: '',
      fallbackUrls: const ['https://mirror.example/book.epub'],
      fast: false,
    );

    expect(target.url, 'https://mirror.example/book.epub');
    expect(target.fallbackUrls, isEmpty);
  });

  test('fast links still win over a refusal', () {
    final target = chooseDownloadTarget(
      url: 'https://cdn.example/book.epub',
      fallbackUrls: const ['https://mirror.example/book.epub'],
      fast: true,
      refusal: 'daily limit reached',
    );

    expect(target.hasUrl, isTrue);
    expect(target.refusal, isNull);
    expect(target.candidateUrls, hasLength(2));
  });
}
