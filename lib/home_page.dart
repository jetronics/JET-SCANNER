import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_document_scanner/google_mlkit_document_scanner.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';

import 'export_page.dart';
import 'scan_store.dart';
import 'settings.dart';
import 'viewer_page.dart';

enum _Action { open, edit, share, rename, delete }

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

  /// Selection mode, used to pick the PDFs to combine. [_selected] holds the
  /// ids in the order they were tapped, which is the order they are joined in.
  bool _selecting = false;
  final List<String> _selected = [];

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

  // ---- Scanning ---------------------------------------------------------------

  /// Image paths from the scanner, tolerant of the field being null or empty.
  List<String> _imagePaths(DocumentScanningResult result) {
    final dynamic images = result.images;
    return images is List
        ? images.whereType<String>().map(uriToPath).toList()
        : const [];
  }

  /// Opens the scanner and returns the scanned page images, or null when the
  /// user cancelled or something went wrong (which is reported on screen).
  Future<List<String>?> _runScanner() async {
    final scanner = DocumentScanner(
      options: DocumentScannerOptions(
        // Pages come back as images; the editor builds the final file.
        documentFormats: {DocumentFormat.jpeg},
        mode: ScannerMode.full,
        pageLimit: 30,
        isGalleryImport: true,
      ),
    );

    try {
      final result = await scanner.scanDocument();
      final pages = _imagePaths(result);
      if (pages.isEmpty) {
        _toast('The scanner returned no pages.');
        return null;
      }
      return pages;
    } on PlatformException catch (e) {
      final text = '${e.code} ${e.message ?? ''}'.toLowerCase();
      if (text.contains('cancel')) {
        _toast('Scan cancelled.');
      } else {
        await _showReport(_describe(e));
      }
      return null;
    } catch (e, stack) {
      await _showReport('$e\n$stack');
      return null;
    } finally {
      try {
        await scanner.close();
      } catch (_) {
        // Releasing the scanner is best effort.
      }
    }
  }

  Future<void> _scan() async {
    if (_scanning) return;
    setState(() => _scanning = true);
    final pages = await _runScanner();
    if (mounted) setState(() => _scanning = false);
    if (pages == null || !mounted) return;

    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ExportPage(
          pages: [for (final path in pages) PageSpec(path)],
          store: _store,
        ),
      ),
    );

    // The scanner's temporary page images are no longer needed: saving keeps
    // its own copy of each original page.
    for (final path in pages) {
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } on FileSystemException {
        // Temporary files; nothing to do if one cannot be removed.
      }
    }

    if (saved == true) {
      await _refresh();
      _toast('Saved.');
    }
  }

  /// Error code, message, details and the first lines of the native stack
  /// trace (which names the exception that was thrown on the Android side).
  String _describe(PlatformException e) {
    final trace = (e.stacktrace ?? '')
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .take(14)
        .join('\n');
    return 'code: ${e.code}\nmessage: ${e.message}\ndetails: ${e.details}'
        '${trace.isEmpty ? '' : '\n$trace'}';
  }

  Future<void> _showReport(
    String report, {
    String title = 'Scanner problem',
  }) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: SelectableText(report)),
        actions: [
          TextButton(
            onPressed: () => Clipboard.setData(ClipboardData(text: report)),
            child: const Text('Copy'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  // ---- Library actions -----------------------------------------------------------

  Future<void> _open(ScanItem item) async {
    if (item.format != OutputFormat.pdf) {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(builder: (_) => ViewerPage(item: item)),
      );
      return;
    }
    final result = await OpenFilex.open(
      item.files.first.path,
      type: 'application/pdf',
    );
    if (result.type == ResultType.done) return;
    _toast(
      result.type == ResultType.noAppToOpen
          ? 'No PDF viewer found. Use Share to send it to another app.'
          : 'Could not open the file: ${result.message}',
    );
  }

  Future<void> _edit(ScanItem item) async {
    if (!item.canEdit) {
      _toast(
        'This scan was saved before editing existed, so its original pages '
        'were not kept. Scan it again to edit it.',
      );
      return;
    }
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ExportPage(
          pages: item.specs,
          store: _store,
          editing: item,
        ),
      ),
    );
    if (saved == true) {
      await _refresh();
      _toast('Changes saved.');
    }
  }

  Future<void> _share(ScanItem item) async {
    try {
      final files = await _store.shareFiles(item);
      await SharePlus.instance.share(
        ShareParams(
          files: [
            for (final file in files)
              XFile(file.path, mimeType: item.format.mimeType),
          ],
          subject: item.name,
        ),
      );
    } on FileSystemException catch (e) {
      _toast('Could not share: ${e.message}');
    }
  }

  Future<void> _rename(ScanItem item) async {
    final newName = await showDialog<String>(
      context: context,
      builder: (_) => _RenameDialog(initial: item.name),
    );
    if (newName == null) return;
    try {
      await _store.rename(item, newName);
      await _refresh();
      _toast('Renamed.');
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
      case _Action.edit:
        _edit(item);
      case _Action.share:
        _share(item);
      case _Action.rename:
        _rename(item);
      case _Action.delete:
        _delete(item);
    }
  }

  // ---- Combining PDFs ----------------------------------------------------------------

  void _startSelecting({ScanItem? first}) {
    final pdfCount =
        _items.where((item) => item.format == OutputFormat.pdf).length;
    if (pdfCount < 2) {
      _toast('You need at least two PDF scans to combine them.');
      return;
    }
    if (first != null && first.format != OutputFormat.pdf) {
      _toast('Only PDF scans can be combined.');
      return;
    }
    setState(() {
      _selecting = true;
      _selected
        ..clear()
        ..addAll([if (first != null) first.id]);
    });
    if (first == null) {
      _toast('Tap the PDFs to combine, in the order you want them joined.');
    }
  }

  void _stopSelecting() => setState(() {
        _selecting = false;
        _selected.clear();
      });

  void _toggle(ScanItem item) {
    if (item.format != OutputFormat.pdf) {
      _toast('Only PDF scans can be combined.');
      return;
    }
    setState(() {
      if (!_selected.remove(item.id)) _selected.add(item.id);
    });
  }

  void _showProgress(String message) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            children: [
              const CircularProgressIndicator(),
              const SizedBox(width: 20),
              Expanded(child: Text(message)),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _combine() async {
    final byId = {for (final item in _items) item.id: item};
    final chosen = [
      for (final id in _selected)
        if (byId[id] != null) byId[id]!,
    ];
    if (chosen.length < 2) {
      _toast('Select at least two PDFs.');
      return;
    }

    final name = await showDialog<String>(
      context: context,
      builder: (_) => _CombineDialog(
        items: chosen,
        initialName: _store.defaultName('Combined'),
      ),
    );
    if (name == null || !mounted) return;
    final clean = sanitizeName(name);
    if (clean.isEmpty) {
      _toast('The name cannot be empty.');
      return;
    }

    _showProgress('Combining ${chosen.length} PDFs...');
    Object? error;
    StackTrace? trace;
    try {
      await _store.combine(name: clean, items: chosen);
    } catch (e, stack) {
      error = e;
      trace = stack;
    }
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop(); // the progress dialog

    if (error != null) {
      await _showReport('$error\n\n$trace', title: 'Could not combine');
      return;
    }
    _stopSelecting();
    await _refresh();
    _toast('Combined ${chosen.length} PDFs.');
  }

  // ---- UI ---------------------------------------------------------------------------

  PreferredSizeWidget _buildAppBar() {
    if (_selecting) {
      return AppBar(
        leading: IconButton(
          tooltip: 'Cancel',
          icon: const Icon(Icons.close),
          onPressed: _stopSelecting,
        ),
        title: Text(
          _selected.isEmpty ? 'Select PDFs' : '${_selected.length} selected',
        ),
        actions: [
          TextButton.icon(
            onPressed: _selected.length >= 2 ? _combine : null,
            icon: const Icon(Icons.merge),
            label: const Text('Combine'),
          ),
        ],
      );
    }
    return AppBar(
      title: const Text('Jet Scanner'),
      actions: [
        IconButton(
          tooltip: 'Combine PDFs',
          icon: const Icon(Icons.merge),
          onPressed: _items.isEmpty ? null : () => _startSelecting(),
        ),
      ],
    );
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
            final position = _selected.indexOf(item.id);
            return _ScanTile(
              item: item,
              selecting: _selecting,
              selectable: item.format == OutputFormat.pdf,
              order: position >= 0 ? position + 1 : null,
              onTap: _selecting ? () => _toggle(item) : () => _open(item),
              onLongPress:
                  _selecting ? null : () => _startSelecting(first: item),
              onAction: (action) => _onAction(action, item),
            );
          },
        ),
      );
    }

    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _stopSelecting();
      },
      child: Scaffold(
        appBar: _buildAppBar(),
        body: body,
        floatingActionButton: _selecting
            ? null
            : FloatingActionButton.extended(
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
      ),
    );
  }
}

class _ScanTile extends StatelessWidget {
  const _ScanTile({
    required this.item,
    required this.selecting,
    required this.selectable,
    required this.order,
    required this.onTap,
    required this.onLongPress,
    required this.onAction,
  });

  final ScanItem item;
  final bool selecting;
  final bool selectable;

  /// 1-based position in the combine order, or null when not selected.
  final int? order;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final ValueChanged<_Action> onAction;

  @override
  Widget build(BuildContext context) {
    final thumb = item.thumbnail;
    final details = <String>[
      item.format.label,
      _paperLabel(item.paperId),
      if (item.pages > 0) (item.pages == 1 ? '1 page' : '${item.pages} pages'),
      _formatSize(item.sizeBytes),
    ];

    final Widget leading = order != null
        ? SizedBox(
            width: 48,
            height: 56,
            child: Center(child: CircleAvatar(child: Text('$order'))),
          )
        : SizedBox(
            width: 48,
            height: 56,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: thumb != null
                  ? Image.file(
                      thumb,
                      fit: BoxFit.cover,
                      cacheWidth: 144,
                      errorBuilder: (context, error, stack) =>
                          const _PdfIcon(),
                    )
                  : const _PdfIcon(),
            ),
          );

    return Opacity(
      opacity: selecting && !selectable ? 0.4 : 1,
      child: ListTile(
        onTap: onTap,
        onLongPress: onLongPress,
        selected: order != null,
        isThreeLine: true,
        leading: leading,
        title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text('${_formatDate(item.created)}\n${details.join('  •  ')}'),
        trailing: selecting
            ? null
            : PopupMenuButton<_Action>(
                onSelected: onAction,
                itemBuilder: (context) => const [
                  PopupMenuItem(value: _Action.open, child: Text('Open')),
                  PopupMenuItem(value: _Action.edit, child: Text('Edit')),
                  PopupMenuItem(value: _Action.share, child: Text('Share')),
                  PopupMenuItem(value: _Action.rename, child: Text('Rename')),
                  PopupMenuItem(value: _Action.delete, child: Text('Delete')),
                ],
              ),
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

/// Asks for the name of the combined PDF and shows the order it will be
/// joined in.
class _CombineDialog extends StatefulWidget {
  const _CombineDialog({required this.items, required this.initialName});

  final List<ScanItem> items;
  final String initialName;

  @override
  State<_CombineDialog> createState() => _CombineDialogState();
}

class _CombineDialogState extends State<_CombineDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialName);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    return AlertDialog(
      title: Text('Combine ${items.length} PDFs'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 16),
            Text('Joined in this order:',
                style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 4),
            for (var i = 0; i < items.length; i++)
              Text(
                '${i + 1}. ${items[i].name}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('Combine'),
        ),
      ],
    );
  }
}

String _paperLabel(String id) => id == 'mixed' ? 'Mixed sizes' : paperById(id).short;

String _formatDate(DateTime d) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

String _formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
