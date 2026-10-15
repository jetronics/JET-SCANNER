import 'package:doc_scanner/scan_store.dart';
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
}
