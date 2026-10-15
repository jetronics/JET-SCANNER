import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Removes characters that are not allowed in file names.
String sanitizeName(String input) {
  final cleaned = input
      .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  // Leading dots would make the file hidden or invalid.
  return cleaned.replaceAll(RegExp(r'^\.+'), '').trim();
}

/// One saved scan: a PDF plus an optional JPEG preview of its first page.
class ScanItem {
  const ScanItem({
    required this.name,
    required this.pdf,
    required this.thumbnail,
    required this.modified,
    required this.sizeBytes,
  });

  /// File name without extension.
  final String name;
  final File pdf;
  final File? thumbnail;
  final DateTime modified;
  final int sizeBytes;
}

/// Keeps scans as plain files in the app's private documents folder.
///
/// Every scan is `<name>.pdf` with an optional `<name>.jpg` preview next to
/// it, so there is no database to keep in sync.
class ScanStore {
  Directory? _cached;

  Future<Directory> _dir() async {
    final existing = _cached;
    if (existing != null) return existing;
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}${Platform.pathSeparator}scans');
    await dir.create(recursive: true);
    return _cached = dir;
  }

  String _path(Directory dir, String base, String ext) =>
      '${dir.path}${Platform.pathSeparator}$base.$ext';

  String _uniqueBase(Directory dir, String wanted) {
    var candidate = wanted;
    var n = 2;
    while (File(_path(dir, candidate, 'pdf')).existsSync()) {
      candidate = '$wanted ($n)';
      n++;
    }
    return candidate;
  }

  String _baseName(String path) {
    final file = path.split(Platform.pathSeparator).last;
    final dot = file.lastIndexOf('.');
    return dot > 0 ? file.substring(0, dot) : file;
  }

  /// The scanner returns `file://` URIs; plain paths are accepted too.
  String _toFilePath(String uriOrPath) {
    final uri = Uri.tryParse(uriOrPath);
    if (uri != null && uri.scheme == 'file') return uri.toFilePath();
    return uriOrPath;
  }

  String _defaultName() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return 'Scan ${now.year}-${two(now.month)}-${two(now.day)} '
        '${two(now.hour)}-${two(now.minute)}-${two(now.second)}';
  }

  /// All saved scans, newest first.
  Future<List<ScanItem>> list() async {
    final dir = await _dir();
    final items = <ScanItem>[];
    await for (final entity in dir.list()) {
      if (entity is! File || !entity.path.toLowerCase().endsWith('.pdf')) {
        continue;
      }
      final stat = await entity.stat();
      final base = _baseName(entity.path);
      final thumb = File(_path(dir, base, 'jpg'));
      items.add(
        ScanItem(
          name: base,
          pdf: entity,
          thumbnail: await thumb.exists() ? thumb : null,
          modified: stat.modified,
          sizeBytes: stat.size,
        ),
      );
    }
    items.sort((a, b) => b.modified.compareTo(a.modified));
    return items;
  }

  /// Copies the scanner's output into the library and removes the temporary
  /// files the scanner left behind.
  Future<ScanItem> save({
    required String pdfUri,
    required List<String> imageUris,
  }) async {
    final dir = await _dir();
    final base = _uniqueBase(dir, _defaultName());

    final pdfFile = await File(_toFilePath(pdfUri)).copy(
      _path(dir, base, 'pdf'),
    );

    File? thumb;
    if (imageUris.isNotEmpty) {
      try {
        thumb = await File(_toFilePath(imageUris.first)).copy(
          _path(dir, base, 'jpg'),
        );
      } on FileSystemException {
        thumb = null; // The preview is optional.
      }
    }

    await _deleteQuietly([pdfUri, ...imageUris]);

    final stat = await pdfFile.stat();
    return ScanItem(
      name: base,
      pdf: pdfFile,
      thumbnail: thumb,
      modified: stat.modified,
      sizeBytes: stat.size,
    );
  }

  Future<void> _deleteQuietly(Iterable<String> uris) async {
    for (final uri in uris) {
      try {
        final file = File(_toFilePath(uri));
        if (await file.exists()) await file.delete();
      } on FileSystemException {
        // Temporary scanner output; nothing to do if it cannot be removed.
      }
    }
  }

  /// Renames a scan and its preview. Returns the name actually used, which
  /// gets a " (2)" style suffix when another scan already has that name.
  Future<String> rename(ScanItem item, String newName) async {
    final clean = sanitizeName(newName);
    if (clean.isEmpty) throw ArgumentError('The name cannot be empty.');
    if (clean == item.name) return item.name;

    final dir = await _dir();
    final base = _uniqueBase(dir, clean);
    await item.pdf.rename(_path(dir, base, 'pdf'));
    final thumb = item.thumbnail;
    if (thumb != null && await thumb.exists()) {
      await thumb.rename(_path(dir, base, 'jpg'));
    }
    return base;
  }

  Future<void> delete(ScanItem item) async {
    if (await item.pdf.exists()) await item.pdf.delete();
    final thumb = item.thumbnail;
    if (thumb != null && await thumb.exists()) await thumb.delete();
  }
}
