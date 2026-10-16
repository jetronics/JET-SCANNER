import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'render.dart';
import 'settings.dart';

/// One saved document: a folder holding the output file(s), a thumbnail and a
/// small `meta.json`.
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
  });

  final String id;
  final String name;
  final OutputFormat format;
  final String paperId;

  /// 0 when unknown (documents saved by the first version of the app).
  final int pages;
  final DateTime created;
  final Directory directory;

  /// The PDF, or one image per page.
  final List<File> files;
  final File? thumbnail;
  final int sizeBytes;
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

  String defaultName() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return 'Scan ${now.year}-${two(now.month)}-${two(now.day)} '
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
      );
    } catch (_) {
      return null; // A damaged entry should never break the whole library.
    }
  }

  // ---- Writing ----------------------------------------------------------------

  /// Renders [pagePaths] with the chosen settings and saves the result.
  Future<ScanItem> create({
    required String name,
    required List<String> pagePaths,
    required OutputFormat format,
    required PaperSize paper,
    required double brightness,
    required double contrast,
  }) async {
    final root = await _dir();
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final dir = Directory(_join(root.path, id));
    await dir.create(recursive: true);

    try {
      final files = await renderDocument(
        RenderRequest(
          pagePaths: pagePaths,
          outDir: dir.path,
          formatId: format.id,
          paperId: paper.id,
          brightness: brightness,
          contrast: contrast,
        ),
      );
      await File(_join(dir.path, metaFileName)).writeAsString(
        jsonEncode({
          'name': name,
          'format': format.id,
          'paper': paper.id,
          'pages': pagePaths.length,
          'created': DateTime.now().toIso8601String(),
          'files': files,
        }),
      );
      final item = await _read(dir);
      if (item == null) {
        throw FileSystemException('The saved document could not be read back.');
      }
      return item;
    } catch (_) {
      if (await dir.exists()) await dir.delete(recursive: true);
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

        await File(_join(dir.path, metaFileName)).writeAsString(
          jsonEncode({
            'name': base,
            'format': 'pdf',
            'paper': 'original',
            'pages': 0,
            'created': (await moved.stat()).modified.toIso8601String(),
            'files': ['output.pdf'],
          }),
        );
      } on FileSystemException {
        // Leave anything that cannot be moved where it is.
      }
    }
  }
}
