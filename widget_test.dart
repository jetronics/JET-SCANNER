import 'package:doc_scanner/settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('sanitizeName', () {
    test('replaces characters that are invalid in file names', () {
      expect(sanitizeName('a/b:c*d'), 'a_b_c_d');
    });

    test('collapses whitespace and trims', () {
      expect(sanitizeName('  Tax   return  '), 'Tax return');
    });

    test('returns empty for blank or dot-only names', () {
      expect(sanitizeName('   '), '');
      expect(sanitizeName('...'), '');
    });

    test('drops leading dots', () {
      expect(sanitizeName('..hidden'), 'hidden');
    });
  });

  group('uriToPath', () {
    test('converts file URIs and leaves plain paths alone', () {
      expect(uriToPath('file:///data/user/0/page.jpg'), '/data/user/0/page.jpg');
      expect(uriToPath('/data/user/0/page.jpg'), '/data/user/0/page.jpg');
    });
  });

  group('paper sizes and formats', () {
    test('paperById finds known ids and falls back to A4', () {
      expect(paperById('legal').short, 'Legal');
      expect(paperById('original').isOriginal, isTrue);
      expect(paperById('nonsense').id, 'a4');
      expect(paperById(null).id, 'a4');
    });

    test('every paper size has a unique id', () {
      final ids = paperSizes.map((p) => p.id).toSet();
      expect(ids.length, paperSizes.length);
    });

    test('OutputFormat.fromId falls back to PDF', () {
      expect(OutputFormat.fromId('png'), OutputFormat.png);
      expect(OutputFormat.fromId('jpeg').extension, 'jpg');
      expect(OutputFormat.fromId('gif'), OutputFormat.pdf);
    });

    test('output file names', () {
      expect(outputFileName(OutputFormat.pdf, 0), 'output.pdf');
      expect(outputFileName(OutputFormat.png, 2), 'page-3.png');
      expect(outputFileName(OutputFormat.jpeg, 0), 'page-1.jpg');
    });
  });

  group('pageAspect', () {
    test('portrait scan on A4 is portrait', () {
      expect(pageAspect(a4Paper, 1000, 1400), closeTo(595.28 / 841.89, 1e-9));
    });

    test('landscape scan on A4 is landscape', () {
      expect(pageAspect(a4Paper, 1400, 1000), closeTo(841.89 / 595.28, 1e-9));
    });

    test('original keeps the scan proportions', () {
      expect(pageAspect(originalPaper, 1200, 800), closeTo(1.5, 1e-9));
    });
  });

  group('brightness and contrast', () {
    test('zero adjustment is the identity', () {
      final lut = buildLut();
      for (var v = 0; v < 256; v++) {
        expect(lut[v], v);
      }
    });

    test('brightness adds levels and clamps at the ends', () {
      final lut = buildLut(brightness: 50);
      expect(lut[0], 50);
      expect(lut[100], 150);
      expect(lut[250], 255);
      expect(buildLut(brightness: -50)[10], 0);
    });

    test('contrast pivots around mid-grey', () {
      final lut = buildLut(contrast: 100); // factor 2
      expect(lut[128], 128);
      expect(lut[138], 148);
      expect(lut[118], 108);
      expect(lut[0], 0);
      expect(lut[255], 255);
    });

    test('lower contrast pulls values toward mid-grey', () {
      final lut = buildLut(contrast: -50); // factor 0.5
      expect(lut[0], 64);
      expect(lut[255], 192);
    });

    test('preview matrix matches the lookup table', () {
      const brightness = 30.0;
      const contrast = 40.0;
      final lut = buildLut(brightness: brightness, contrast: contrast);
      final m = previewMatrix(brightness: brightness, contrast: contrast);
      for (final v in [0, 40, 128, 200, 255]) {
        final fromMatrix = (m[0] * v + m[4]).round().clamp(0, 255);
        expect(fromMatrix, lut[v], reason: 'input $v');
      }
    });
  });
}
