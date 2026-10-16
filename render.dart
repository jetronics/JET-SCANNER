// Turns scanned page images into the final document. Pure Dart, and it runs in
// a background isolate so the app stays responsive while pages are processed.
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'settings.dart';

/// Resolution used when a page is fitted to a paper size.
const int _dpi = 200;

class RenderRequest {
  const RenderRequest({
    required this.pagePaths,
    required this.outDir,
    required this.formatId,
    required this.paperId,
    required this.brightness,
    required this.contrast,
  });

  final List<String> pagePaths;
  final String outDir;
  final String formatId;
  final String paperId;

  /// One value per page, in the same order as [pagePaths].
  final List<double> brightness;
  final List<double> contrast;
}

/// Writes the document (and a thumbnail) into [RenderRequest.outDir] and
/// returns the names of the document files, in page order.
Future<List<String>> renderDocument(RenderRequest request) =>
    Isolate.run(() => _render(request));

Future<List<String>> _render(RenderRequest request) async {
  final format = OutputFormat.fromId(request.formatId);
  final paper = paperById(request.paperId);
  final pdf = format == OutputFormat.pdf ? pw.Document() : null;
  final written = <String>[];

  for (var i = 0; i < request.pagePaths.length; i++) {
    final brightness = request.brightness[i];
    final contrast = request.contrast[i];
    final lut = (brightness == 0 && contrast == 0)
        ? null
        : buildLut(brightness: brightness, contrast: contrast);
    final page = _loadAdjusted(request.pagePaths[i], lut);

    if (i == 0) {
      final thumb = img.copyResize(
        page,
        width: 240,
        interpolation: img.Interpolation.linear,
      );
      File('${request.outDir}/$thumbFileName')
          .writeAsBytesSync(img.encodeJpg(thumb, quality: 80));
    }

    if (format == OutputFormat.pdf) {
      final fitted = paper.isOriginal ? page : _shrinkToFit(page, paper);
      final jpeg = img.encodeJpg(fitted, quality: 85);
      final pageFormat = paper.isOriginal
          ? PdfPageFormat(page.width * 72 / _dpi, page.height * 72 / _dpi)
          : _pdfFormatFor(paper, page);
      pdf!.addPage(
        pw.Page(
          pageFormat: pageFormat,
          margin: pw.EdgeInsets.zero,
          build: (context) => pw.Center(
            child: pw.Image(pw.MemoryImage(jpeg), fit: pw.BoxFit.contain),
          ),
        ),
      );
    } else {
      final out = paper.isOriginal ? page : _placeOnPaper(page, paper);
      final bytes = format == OutputFormat.jpeg
          ? img.encodeJpg(out, quality: 92)
          : img.encodePng(out);
      final name = outputFileName(format, i);
      File('${request.outDir}/$name').writeAsBytesSync(bytes);
      written.add(name);
    }
  }

  if (pdf != null) {
    final name = outputFileName(format, 0);
    File('${request.outDir}/$name').writeAsBytesSync(await pdf.save());
    written.add(name);
  }
  return written;
}

/// Reads a page, applies its EXIF rotation and the brightness/contrast table.
img.Image _loadAdjusted(String path, Uint8List? lut) {
  final decoded = img.decodeImage(File(path).readAsBytesSync());
  if (decoded == null) {
    throw FormatException('Could not read the scanned page: $path');
  }
  final upright = img.bakeOrientation(decoded);

  // Work on a private copy of the plain RGB bytes.
  final rgb = Uint8List.fromList(
    upright.getBytes(order: img.ChannelOrder.rgb),
  );
  if (lut != null) {
    for (var i = 0; i < rgb.length; i++) {
      rgb[i] = lut[rgb[i]];
    }
  }
  return img.Image.fromBytes(
    width: upright.width,
    height: upright.height,
    bytes: rgb.buffer,
    numChannels: 3,
    order: img.ChannelOrder.rgb,
  );
}

/// Pixel size of [paper] at [_dpi], flipped for landscape pages.
(int, int) _paperPixels(PaperSize paper, {required bool landscape}) {
  final w = (landscape ? paper.heightPt : paper.widthPt) * _dpi / 72;
  final h = (landscape ? paper.widthPt : paper.heightPt) * _dpi / 72;
  return (w.round(), h.round());
}

PdfPageFormat _pdfFormatFor(PaperSize paper, img.Image page) {
  final landscape = page.width > page.height;
  return PdfPageFormat(
    landscape ? paper.heightPt : paper.widthPt,
    landscape ? paper.widthPt : paper.heightPt,
  );
}

/// Shrinks a page that is bigger than the paper (never enlarges it), which
/// keeps PDFs from growing huge.
img.Image _shrinkToFit(img.Image page, PaperSize paper) {
  final (maxW, maxH) = _paperPixels(paper, landscape: page.width > page.height);
  final scale = math.min(1.0, math.min(maxW / page.width, maxH / page.height));
  if (scale >= 1) return page;
  return img.copyResize(
    page,
    width: math.max(1, (page.width * scale).round()),
    height: math.max(1, (page.height * scale).round()),
    interpolation: img.Interpolation.linear,
  );
}

/// Centres the page on a white canvas the size of the paper.
img.Image _placeOnPaper(img.Image page, PaperSize paper) {
  final (canvasW, canvasH) =
      _paperPixels(paper, landscape: page.width > page.height);
  final scale = math.min(canvasW / page.width, canvasH / page.height);
  final w = math.max(1, (page.width * scale).round());
  final h = math.max(1, (page.height * scale).round());

  final resized = img.copyResize(
    page,
    width: w,
    height: h,
    interpolation: img.Interpolation.linear,
  );
  final canvas = img.Image(width: canvasW, height: canvasH);
  img.fill(canvas, color: img.ColorRgb8(255, 255, 255));
  img.compositeImage(
    canvas,
    resized,
    dstX: (canvasW - w) ~/ 2,
    dstY: (canvasH - h) ~/ 2,
  );
  return canvas;
}
