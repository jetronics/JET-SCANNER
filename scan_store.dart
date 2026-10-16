import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:pdf_combiner/exception/pdf_combiner_exception.dart';
import 'package:pdf_combiner/models/merge_input.dart';
import 'package:pdf_combiner/pdf_combiner.dart';

import 'render.dart';
import 'settings.dart';

/// One saved document: a folder holding the output file(s), a thumbnail, the
/// original scanned pages and a small `meta.json`.
class ScanItem {
  const ScanItem({
    required this.id,
    required this.name,
    required this.format,
    required this.paperId,
    required this.pages,
    required this.created,
    required this.directory,
    required this.files,
    required this.thumbnail,
    required this.sizeBytes,
    required this.specs,
  });

  final String id;
  final String name;
  final OutputFormat format;

  /// A [paperSizes] id, or `mixed` for a combined PDF made of different sizes.
  final String paperId;

  /// 0 when unknown (documents saved by the first version of the app).
  final int pages;
  final DateTime created;
  final Directory directory;

  /// The PDF, or one image per page.
  final List<File> files;
  final File? thumbnail;
  final int sizeBytes;

  /// The original pages with their brightness/contrast. Empty for documents
  /// saved before editing existed, which therefore cannot be edited.
  final List<PageSpec> specs;

  bool get canEdit => specs.isNotEmpty;
}

/// The paper size and format used last time, so they are pre-selected.
class ExportPrefs {
  const ExportPrefs({this.paperId = 'a4', this.formatId = 'pdf'});

  final String paperId;
  final String formatId;
}

/// Keeps documents as plain files in the app's private documents folder, so
/// there is no database to keep in sync.
class ScanStore {
  Directory? _cached;

  String get _sep => Platform.pathSeparator;

  String _join(String a, String b) => '$a$_sep$b';

  String _lastSegment(String path) => path.split(_sep).last;

  Future<Directory> _dir() async {
    final existing = _cached;
    if (existing != null) return existing;
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(_join(docs.path, 'scans'));
    await dir.create(recursive: true);
    return _cached = dir;
  }

  String defaultName([String prefix = 'Scan']) {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '$prefix ${now.year}-${two(now.month)}-${two(now.day)} '
        '${two(now.hour)}-${two(now.minute)}-${two(now.second)}';
  }

  // ---- Preferences ------------------------------------------------------------

  Future<File> _prefsFile() async =>
      File(_join((await _dir()).parent.path, 'prefs.json'));

  Future<ExportPrefs> loadPrefs() async {
    try {
      final file = await _prefsFile();
      if (!await file.exists()) return const ExportPrefs();
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return ExportPrefs(
        paperId: json['paper'] as String? ?? 'a4',
        formatId: json['format'] as String? ?? 'pdf',
      );
    } catch (_) {
      return const ExportPrefs();
    }
  }

  Future<void> savePrefs(ExportPrefs prefs) async {
    try {
      final file = await _prefsFile();
      await file.writeAsString(
        jsonEncode({'paper': prefs.paperId, 'format': prefs.formatId}),
      );
    } catch (_) {
      // Remembering the last choice is a nicety, not worth failing a save.
    }
  }

  // ---- Reading ----------------------------------------------------------------

  /// All saved documents, newest first.
  Future<List<ScanItem>> list() async {
    final root = await _dir();
    await _migrateLegacy(root);

    final items = <ScanItem>[];
    await for (final entity in root.list()) {
      if (entity is! Directory) continue;
      final item = await _read(entity);
      if (item != null) items.add(item);
    }
    items.sort((a, b) => b.created.compareTo(a.created));
    return items;
  }

  Future<ScanItem?> _read(Directory dir) async {
    try {
      final metaFile = File(_join(dir.path, metaFileName));
      if (!await metaFile.exists()) return null;
      final json =
          jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;

      final files = <File>[];
      var size = 0;
      for (final name in (json['files'] as List).cast<String>()) {
        final file = File(_join(dir.path, name));
        if (await file.exists()) {
          files.add(file);
          size += await file.length();
        }
      }
      if (files.isEmpty) return null;

      // Original pages. If any is missing the document is simply not editable.
      final sourceNames = (json['sources'] as List?)?.cast<String>() ?? const [];
      final adjust = json['adjust'] as List?;
      final specs = <PageSpec>[];
      for (var i = 0; i < sourceNames.length; i++) {
        final source = File(_join(dir.path, sourceNames[i]));
        if (!await source.exists()) {
          specs.clear();
          break;
        }
        var brightness = 0.0;
        var contrast = 0.0;
        if (adjust != null && i < adjust.length) {
          final pair = adjust[i] as List;
          brightness = (pair[0] as num).toDouble();
          contrast = (pair[1] as num).toDouble();
        }
        specs.add(
          PageSpec(source.path, brightness: brightness, contrast: contrast),
        );
      }

      final thumb = File(_join(dir.path, thumbFileName));
      return ScanItem(
        id: _lastSegment(dir.path),
        name: json['name'] as String,
        format: OutputFormat.fromId(json['format'] as String?),
        paperId: json['paper'] as String? ?? 'original',
        pages: (json['pages'] as num?)?.toInt() ?? files.length,
        created: DateTime.tryParse(json['created'] as String? ?? '') ??
            (await metaFile.stat()).modified,
        directory: dir,
        files: files,
        thumbnail: await thumb.exists() ? thumb : null,
        sizeBytes: size,
        specs: specs,
      );
    } catch (_) {
      return null; // A damaged entry should never break the whole library.
    }
  }

  // ---- Writing ----------------------------------------------------------------

  Future<void> _writeMeta(
    Directory dir, {
    required String name,
    required String formatId,
    required String paperId,
    required int pages,
    required DateTime created,
    required List<String> files,
    List<String> sources = const [],
    List<List<double>> adjust = const [],
  }) {
    return File(_join(dir.path, metaFileName)).writeAsString(
      jsonEncode({
        'name': name,
        'format': formatId,
        'paper': paperId,
        'pages': pages,
        'created': created.toIso8601String(),
        'files': files,
        'sources': sources,
        'adjust': adjust,
      }),
    );
  }

  Future<void> _deleteDir(Directory dir) async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {
      // Nothing more can be done about a folder that cannot be removed.
    }
  }

  /// Renders [pages] with the chosen settings and saves the result as a new
  /// document. A private copy of every original page is kept so the document
  /// can be edited again. When [replacing] is given (an edit), the old version
  /// is deleted once the new one has been saved, and the creation date is kept.
  Future<ScanItem> save({
    required String name,
    required List<PageSpec> pages,
    required OutputFormat format,
    required PaperSize paper,
    ScanItem? replacing,
  }) async {
    if (pages.isEmpty) throw ArgumentError('There are no pages to save.');

    final root = await _dir();
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final dir = Directory(_join(root.path, id));
    final sourceDir = Directory(_join(dir.path, sourceDirName));
    await sourceDir.create(recursive: true);

    try {
      final sourcePaths = <String>[];
      final sourceNames = <String>[];
      for (var i = 0; i < pages.length; i++) {
        final fileName = 'p${i + 1}.jpg';
        final copy = await File(pages[i].path).copy(
          _join(sourceDir.path, fileName),
        );
        sourcePaths.add(copy.path);
        sourceNames.add('$sourceDirName/$fileName');
      }

      final files = await renderDocument(
        RenderRequest(
          pagePaths: sourcePaths,
          outDir: dir.path,
          formatId: format.id,
          paperId: paper.id,
          brightness: [for (final p in pages) p.brightness],
          contrast: [for (final p in pages) p.contrast],
        ),
      );

      await _writeMeta(
        dir,
        name: name,
        formatId: format.id,
        paperId: paper.id,
        pages: pages.length,
        created: replacing?.created ?? DateTime.now(),
        files: files,
        sources: sourceNames,
        adjust: [
          for (final p in pages) [p.brightness, p.contrast],
        ],
      );

      final item = await _read(dir);
      if (item == null) {
        throw FileSystemException('The saved document could not be read back.');
      }
      if (replacing != null) await _deleteDir(replacing.directory);
      return item;
    } catch (_) {
      await _deleteDir(dir);
      rethrow;
    }
  }

  /// Joins PDFs, in the given order, into one new PDF. The originals are kept.
  /// Works on any PDF, including ones saved by earlier versions of the app.
  /// If every input can still be edited, so can the combined result.
  Future<ScanItem> combine({
    required String name,
    required List<ScanItem> items,
  }) async {
    if (items.length < 2) throw ArgumentError('Select at least two PDFs.');
    if (items.any((item) => item.format != OutputFormat.pdf)) {
      throw ArgumentError('Only PDF scans can be combined.');
    }

    final root = await _dir();
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final dir = Directory(_join(root.path, id));
    await dir.create(recursive: true);

    try {
      final outputPath = _join(dir.path, 'output.pdf');
      await PdfCombiner.mergeMultiplePDFs(
        inputs: [
          for (final item in items) MergeInput.path(item.files.first.path),
        ],
        outputPath: outputPath,
      );

      final firstThumb = items.first.thumbnail;
      if (firstThumb != null) {
        try {
          await firstThumb.copy(_join(dir.path, thumbFileName));
        } on FileSystemException {
          // The thumbnail is optional.
        }
      }

      // Keep the original pages when every input has them, so the combined
      // PDF can be edited later page by page.
      final sourceNames = <String>[];
      final adjust = <List<double>>[];
      if (items.every((item) => item.canEdit)) {
        await Directory(_join(dir.path, sourceDirName)).create(recursive: true);
        var n = 0;
        for (final item in items) {
          for (final spec in item.specs) {
            n++;
            final relative = '$sourceDirName/p$n.jpg';
            await File(spec.path).copy(_join(dir.path, relative));
            sourceNames.add(relative);
            adjust.add([spec.brightness, spec.contrast]);
          }
        }
      }

      final papers = items.map((item) => item.paperId).toSet();
      final knownPages = items.every((item) => item.pages > 0);
      await _writeMeta(
        dir,
        name: name,
        formatId: OutputFormat.pdf.id,
        paperId: papers.length == 1 ? papers.first : 'mixed',
        pages: knownPages ? items.fold(0, (sum, item) => sum + item.pages) : 0,
        created: DateTime.now(),
        files: ['output.pdf'],
        sources: sourceNames,
        adjust: adjust,
      );

      final item = await _read(dir);
      if (item == null) {
        throw FileSystemException('The combined PDF could not be read back.');
      }
      return item;
    } on PdfCombinerException catch (e) {
      await _deleteDir(dir);
      throw StateError('Could not combine the PDFs: ${e.message}');
    } catch (_) {
      await _deleteDir(dir);
      rethrow;
    }
  }

  /// Renames a document. Returns the name actually used.
  Future<String> rename(ScanItem item, String newName) async {
    final clean = sanitizeName(newName);
    if (clean.isEmpty) throw ArgumentError('The name cannot be empty.');

    final metaFile = File(_join(item.directory.path, metaFileName));
    final json =
        jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
    json['name'] = clean;
    await metaFile.writeAsString(jsonEncode(json));
    return clean;
  }

  Future<void> delete(ScanItem item) async {
    if (await item.directory.exists()) {
      await item.directory.delete(recursive: true);
    }
  }

  /// Copies the document's files to a temporary folder under their proper
  /// names ("<name>.pdf", "<name> 1.jpg", ...) so that is what a recipient sees.
  Future<List<File>> shareFiles(ScanItem item) async {
    final tmp = await getTemporaryDirectory();
    final dir = Directory(_join(tmp.path, 'share'));
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);

    final clean = sanitizeName(item.name);
    final base = clean.isEmpty ? 'scan' : clean;
    final ext = item.format.extension;

    final out = <File>[];
    for (var i = 0; i < item.files.length; i++) {
      final fileName =
          item.files.length == 1 ? '$base.$ext' : '$base ${i + 1}.$ext';
      out.add(await item.files[i].copy(_join(dir.path, fileName)));
    }
    return out;
  }

  // ---- Upgrading from version 1 ---------------------------------------------

  /// Version 1 stored `<name>.pdf` (+ `<name>.jpg`) directly in the scans
  /// folder. Move those into the folder-per-document layout.
  Future<void> _migrateLegacy(Directory root) async {
    final legacy = <File>[];
    await for (final entity in root.list()) {
      if (entity is File && entity.path.toLowerCase().endsWith('.pdf')) {
        legacy.add(entity);
      }
    }

    final stamp = DateTime.now().microsecondsSinceEpoch;
    for (var i = 0; i < legacy.length; i++) {
      try {
        final pdf = legacy[i];
        final file = _lastSegment(pdf.path);
        final base = file.substring(0, file.length - '.pdf'.length);

        final dir = Directory(_join(root.path, 'legacy-$stamp-$i'));
        await dir.create();

        final moved = await pdf.rename(_join(dir.path, 'output.pdf'));
        final oldThumb = File(_join(root.path, '$base.jpg'));
        if (await oldThumb.exists()) {
          await oldThumb.rename(_join(dir.path, thumbFileName));
        }

        await _writeMeta(
          dir,
          name: base,
          formatId: 'pdf',
          paperId: 'original',
          pages: 0,
          created: (await moved.stat()).modified,
          files: ['output.pdf'],
        );
      } on FileSystemException {
        // Leave anything that cannot be moved where it is.
      }
    }
  }
}
