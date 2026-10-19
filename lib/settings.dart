// Pure Dart (no Flutter imports) so it can be used from a background isolate
// and unit-tested without a device.
import 'dart:typed_data';

/// A paper size in PDF points (1/72 inch), portrait orientation.
class PaperSize {
  const PaperSize(this.id, this.label, this.short, this.widthPt, this.heightPt);

  final String id;
  final String label;
  final String short;
  final double widthPt;
  final double heightPt;

  /// "Original" keeps every page at the size it was scanned.
  bool get isOriginal => widthPt == 0 || heightPt == 0;
}

const PaperSize originalPaper = PaperSize(
  'original',
  'Original (as scanned)',
  'Original',
  0,
  0,
);

const PaperSize a4Paper = PaperSize(
  'a4',
  'A4 (210 × 297 mm)',
  'A4',
  595.28,
  841.89,
);

const List<PaperSize> paperSizes = <PaperSize>[
  originalPaper,
  a4Paper,
  PaperSize('a5', 'A5 (148 × 210 mm)', 'A5', 419.53, 595.28),
  PaperSize('a3', 'A3 (297 × 420 mm)', 'A3', 841.89, 1190.55),
  PaperSize('letter', 'Letter (8.5 × 11 in)', 'Letter', 612, 792),
  PaperSize('legal', 'Legal (8.5 × 14 in)', 'Legal', 612, 1008),
  PaperSize('long', 'Long bond (8.5 × 13 in)', 'Long bond', 612, 936),
];

/// Looks a paper size up by id; unknown ids fall back to A4.
PaperSize paperById(String? id) {
  for (final paper in paperSizes) {
    if (paper.id == id) return paper;
  }
  return a4Paper;
}

enum OutputFormat {
  pdf('pdf', 'PDF', 'pdf', 'application/pdf'),
  jpeg('jpeg', 'JPEG', 'jpg', 'image/jpeg'),
  png('png', 'PNG', 'png', 'image/png');

  const OutputFormat(this.id, this.label, this.extension, this.mimeType);

  final String id;
  final String label;
  final String extension;
  final String mimeType;

  static OutputFormat fromId(String? id) {
    for (final format in values) {
      if (format.id == id) return format;
    }
    return pdf;
  }
}

/// File names used inside a saved document's folder.
const String metaFileName = 'meta.json';
const String thumbFileName = 'thumb.jpg';

String outputFileName(OutputFormat format, int pageIndex) =>
    format == OutputFormat.pdf
        ? 'output.pdf'
        : 'page-${pageIndex + 1}.${format.extension}';

/// Folder (inside a document's folder) that keeps the original scanned pages,
/// so a scan can be edited again later.
const String sourceDirName = 'source';

/// One page going into a document: the original scanned image plus the
/// brightness and contrast chosen for that page.
class PageSpec {
  const PageSpec(this.path, {this.brightness = 0, this.contrast = 0});

  final String path;
  final double brightness;
  final double contrast;
}

// ---- Brightness and contrast ------------------------------------------------
//
// Both the on-screen preview and the exported pixels use the same formula, so
// what you see is what you save:
//
//     out = (in - 128) * contrastFactor + 128 + brightness      (0..255 levels)
//
// brightness: -100..100 (levels added to every channel)
// contrast:   -50..100  (percent; 0 leaves the image unchanged)

double contrastFactor(double contrast) => 1 + contrast / 100;

/// A 256-entry lookup table that applies the adjustment to one 8-bit channel.
Uint8List buildLut({double brightness = 0, double contrast = 0}) {
  final factor = contrastFactor(contrast);
  final lut = Uint8List(256);
  for (var value = 0; value < 256; value++) {
    final out = ((value - 128) * factor + 128 + brightness).round();
    lut[value] = out < 0 ? 0 : (out > 255 ? 255 : out);
  }
  return lut;
}

/// The same adjustment as a 5x4 colour matrix for Flutter's `ColorFilter`
/// (whose last column is in 0..255 units).
List<double> previewMatrix({double brightness = 0, double contrast = 0}) {
  final f = contrastFactor(contrast);
  final t = 128 * (1 - f) + brightness;
  return <double>[
    f, 0, 0, 0, t, //
    0, f, 0, 0, t, //
    0, 0, f, 0, t, //
    0, 0, 0, 1, 0, //
  ];
}

/// Width / height of a page after fitting it to [paper]. Landscape scans get a
/// landscape page, portrait scans a portrait one.
double pageAspect(PaperSize paper, num imageWidth, num imageHeight) {
  if (paper.isOriginal) return imageWidth / imageHeight;
  final portrait = paper.widthPt / paper.heightPt;
  return imageWidth > imageHeight ? 1 / portrait : portrait;
}

// ---- Small helpers --------------------------------------------------------------

/// Removes characters that are not allowed in file names.
String sanitizeName(String input) {
  final cleaned = input
      .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  // Leading dots would make the file hidden or invalid.
  return cleaned.replaceAll(RegExp(r'^\.+'), '').trim();
}

/// The scanner returns plain paths; `file://` URIs are accepted too.
String uriToPath(String uriOrPath) {
  final uri = Uri.tryParse(uriOrPath);
  if (uri != null && uri.scheme == 'file') return uri.toFilePath();
  return uriOrPath;
}
