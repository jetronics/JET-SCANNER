import 'dart:io';

import 'package:doc_scanner/render.dart';
import 'package:doc_scanner/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// Renders a small synthetic two-page scan in every format. This exercises the
/// same code the app runs after scanning, without needing a phone.
void main() {
  late Directory work;
  late List<String> pages;

  setUpAll(() {
    work = Directory.systemTemp.createTempSync('jet_scanner_test_');
    pages = <String>[];

    // Page 1: landscape, grey 100. Page 2: portrait, grey 200.
    final specs = [(600, 400, 100), (400, 600, 200)];
    for (var i = 0; i < specs.length; i++) {
      final (w, h, grey) = specs[i];
      final image = img.Image(width: w, height: h);
      img.fill(image, color: img.ColorRgb8(grey, grey, grey));
      final file = File('${work.path}/page$i.jpg')
        ..writeAsBytesSync(img.encodeJpg(image, quality: 95));
      pages.add(file.path);
    }
  });

  tearDownAll(() => work.deleteSync(recursive: true));

  Future<(Directory, List<String>)> run(
    OutputFormat format,
    String paperId, {
    List<double> brightness = const [0, 0],
    List<double> contrast = const [0, 0],
  }) async {
    final out = Directory(
      '${work.path}/out_${format.id}_${paperId}_${brightness.join(',')}_${contrast.join(',')}',
    )..createSync();
    final files = await renderDocument(
      RenderRequest(
        pagePaths: pages,
        outDir: out.path,
        formatId: format.id,
        paperId: paperId,
        brightness: brightness,
        contrast: contrast,
      ),
    );
    return (out, files);
  }

  test('PDF: one file, valid header, thumbnail written', () async {
    final (out, files) = await run(OutputFormat.pdf, 'a4');
    expect(files, ['output.pdf']);
    final bytes = File('${out.path}/output.pdf').readAsBytesSync();
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    expect(File('${out.path}/$thumbFileName').existsSync(), isTrue);
  });

  test('JPEG on A4: one image per page, fitted to the paper', () async {
    final (out, files) = await run(OutputFormat.jpeg, 'a4');
    expect(files, ['page-1.jpg', 'page-2.jpg']);

    final landscape = img.decodeImage(
      File('${out.path}/page-1.jpg').readAsBytesSync(),
    )!;
    final portrait = img.decodeImage(
      File('${out.path}/page-2.jpg').readAsBytesSync(),
    )!;
    expect(landscape.width / landscape.height, closeTo(841.89 / 595.28, 0.01));
    expect(portrait.width / portrait.height, closeTo(595.28 / 841.89, 0.01));
  });

  test('PNG at original size keeps the scanned dimensions', () async {
    final (out, files) = await run(OutputFormat.png, 'original');
    expect(files, ['page-1.png', 'page-2.png']);
    final first = img.decodeImage(
      File('${out.path}/page-1.png').readAsBytesSync(),
    )!;
    expect((first.width, first.height), (600, 400));
  });

  test('each page gets its own brightness', () async {
    // Page 1 (grey 100) +50 -> 150. Page 2 (grey 200) -50 -> 150.
    final (out, _) = await run(
      OutputFormat.png,
      'original',
      brightness: const [50, -50],
    );
    final first = img.decodeImage(
      File('${out.path}/page-1.png').readAsBytesSync(),
    )!;
    final second = img.decodeImage(
      File('${out.path}/page-2.png').readAsBytesSync(),
    )!;
    // JPEG compression of the source allows a little drift.
    expect(first.getPixel(300, 200).r.toInt(), inInclusiveRange(145, 155));
    expect(second.getPixel(200, 300).r.toInt(), inInclusiveRange(145, 155));
  });

  test('pages with no adjustment are left untouched', () async {
    final (out, _) = await run(
      OutputFormat.png,
      'original',
      brightness: const [0, 50],
    );
    final first = img.decodeImage(
      File('${out.path}/page-1.png').readAsBytesSync(),
    )!;
    expect(first.getPixel(300, 200).r.toInt(), inInclusiveRange(95, 105));
  });
}
