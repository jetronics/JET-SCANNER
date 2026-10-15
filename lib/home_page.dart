import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_document_scanner/google_mlkit_document_scanner.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';

import 'scan_store.dart';

enum _Action { open, share, rename, delete }

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final ScanStore _store = ScanStore();
  List<ScanItem> _items = const [];
  bool _loading = true;
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final items = await _store.list();
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// Image paths from the scanner, tolerant of the field being null or empty.
  List<String> _imagePaths(DocumentScanningResult result) {
    final dynamic images = result.images;
    return images is List ? images.whereType<String>().toList() : const [];
  }

  Future<void> _scan() async {
    if (_scanning) return;
    setState(() => _scanning = true);

    final scanner = DocumentScanner(
      options: DocumentScannerOptions(
        documentFormats: {DocumentFormat.pdf, DocumentFormat.jpeg},
        mode: ScannerMode.full,
        pageLimit: 30,
        isGalleryImport: true,
      ),
    );

    try {
      final result = await scanner.scanDocument();
      final pdf = result.pdf;
      if (pdf == null) {
        _toast('The scanner did not return a PDF.');
        return;
      }
      final item = await _store.save(
        pdfUri: pdf.uri.toString(),
        imageUris: _imagePaths(result),
      );
      await _refresh();
      _toast('Saved "${item.name}"');
    } on PlatformException catch (e) {
      final text = '${e.code} ${e.message ?? ''}'.toLowerCase();
      _toast(
        text.contains('cancel')
            ? 'Scan cancelled.'
            : 'Scan failed: ${e.message ?? e.code}',
      );
    } catch (e) {
      _toast('Scan failed: $e');
    } finally {
      try {
        await scanner.close();
      } catch (_) {
        // Releasing the scanner is best effort.
      }
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _open(ScanItem item) async {
    final result = await OpenFilex.open(item.pdf.path, type: 'application/pdf');
    if (result.type == ResultType.done) return;
    _toast(
      result.type == ResultType.noAppToOpen
          ? 'No PDF viewer found. Use Share to send it to another app.'
          : 'Could not open the file: ${result.message}',
    );
  }

  Future<void> _share(ScanItem item) async {
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(item.pdf.path, mimeType: 'application/pdf')],
        subject: item.name,
      ),
    );
  }

  Future<void> _rename(ScanItem item) async {
    final newName = await showDialog<String>(
      context: context,
      builder: (_) => _RenameDialog(initial: item.name),
    );
    if (newName == null) return;
    try {
      final used = await _store.rename(item, newName);
      await _refresh();
      _toast(
        used == sanitizeName(newName)
            ? 'Renamed.'
            : 'That name is taken, saved as "$used".',
      );
    } on ArgumentError {
      _toast('The name cannot be empty.');
    } on FileSystemException catch (e) {
      _toast('Could not rename: ${e.message}');
    }
  }

  Future<void> _delete(ScanItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete scan?'),
        content: Text('"${item.name}" will be permanently deleted.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _store.delete(item);
      await _refresh();
      _toast('Deleted.');
    } on FileSystemException catch (e) {
      _toast('Could not delete: ${e.message}');
    }
  }

  void _onAction(_Action action, ScanItem item) {
    switch (action) {
      case _Action.open:
        _open(item);
      case _Action.share:
        _share(item);
      case _Action.rename:
        _rename(item);
      case _Action.delete:
        _delete(item);
    }
  }

  @override
  Widget build(BuildContext context) {
    final Widget body;
    if (_loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_items.isEmpty) {
      body = const _EmptyState();
    } else {
      body = RefreshIndicator(
        onRefresh: _refresh,
        child: ListView.separated(
          padding: const EdgeInsets.only(bottom: 96),
          itemCount: _items.length,
          separatorBuilder: (context, index) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final item = _items[index];
            return _ScanTile(
              item: item,
              onTap: () => _open(item),
              onAction: (action) => _onAction(action, item),
            );
          },
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Doc Scanner')),
      body: body,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _scanning ? null : _scan,
        icon: _scanning
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.document_scanner),
        label: Text(_scanning ? 'Scanning...' : 'Scan'),
      ),
    );
  }
}

class _ScanTile extends StatelessWidget {
  const _ScanTile({
    required this.item,
    required this.onTap,
    required this.onAction,
  });

  final ScanItem item;
  final VoidCallback onTap;
  final ValueChanged<_Action> onAction;

  @override
  Widget build(BuildContext context) {
    final thumb = item.thumbnail;
    return ListTile(
      onTap: onTap,
      leading: SizedBox(
        width: 48,
        height: 56,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: thumb != null
              ? Image.file(
                  thumb,
                  fit: BoxFit.cover,
                  cacheWidth: 144,
                  errorBuilder: (context, error, stack) => const _PdfIcon(),
                )
              : const _PdfIcon(),
        ),
      ),
      title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${_formatDate(item.modified)}  •  ${_formatSize(item.sizeBytes)}',
      ),
      trailing: PopupMenuButton<_Action>(
        onSelected: onAction,
        itemBuilder: (context) => const [
          PopupMenuItem(value: _Action.open, child: Text('Open')),
          PopupMenuItem(value: _Action.share, child: Text('Share')),
          PopupMenuItem(value: _Action.rename, child: Text('Rename')),
          PopupMenuItem(value: _Action.delete, child: Text('Delete')),
        ],
      ),
    );
  }
}

class _PdfIcon extends StatelessWidget {
  const _PdfIcon();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: const Icon(Icons.picture_as_pdf),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.document_scanner_outlined, size: 72),
            const SizedBox(height: 16),
            Text('No scans yet', style: textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              'Tap Scan to capture a document or import a photo from your gallery.',
              textAlign: TextAlign.center,
              style: textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initial});

  final String initial;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rename scan'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Name'),
        onSubmitted: (value) => Navigator.pop(context, value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('Rename'),
        ),
      ],
    );
  }
}

String _formatDate(DateTime d) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

String _formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
