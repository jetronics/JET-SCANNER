import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'scan_store.dart';
import 'settings.dart';

/// Shown right after scanning: preview the pages, choose paper size, format,
/// brightness and contrast, then save. Pops with `true` when saved.
class ExportPage extends StatefulWidget {
  const ExportPage({super.key, required this.pagePaths, required this.store});

  final List<String> pagePaths;
  final ScanStore store;

  @override
  State<ExportPage> createState() => _ExportPageState();
}

class _ExportPageState extends State<ExportPage> {
  late final TextEditingController _name =
      TextEditingController(text: widget.store.defaultName());
  final PageController _pages = PageController();
  final Map<int, Future<Size>> _sizes = {};

  PaperSize _paper = a4Paper;
  OutputFormat _format = OutputFormat.pdf;
  double _brightness = 0;
  double _contrast = 0;
  int _current = 0;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  @override
  void dispose() {
    _name.dispose();
    _pages.dispose();
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    final prefs = await widget.store.loadPrefs();
    if (!mounted) return;
    setState(() {
      _paper = paperById(prefs.paperId);
      _format = OutputFormat.fromId(prefs.formatId);
    });
  }

  /// Pixel size of a page, read from the file header without decoding it.
  Future<Size> _sizeOf(int index) => _sizes.putIfAbsent(index, () async {
        final bytes = await File(widget.pagePaths[index]).readAsBytes();
        final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
        try {
          final descriptor = await ui.ImageDescriptor.encoded(buffer);
          final size = Size(
            descriptor.width.toDouble(),
            descriptor.height.toDouble(),
          );
          descriptor.dispose();
          return size;
        } finally {
          buffer.dispose();
        }
      });

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<bool> _confirmDiscard() async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard this scan?'),
        content: const Text('The scanned pages have not been saved yet.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep editing'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    return discard == true;
  }

  Future<void> _save() async {
    final name = sanitizeName(_name.text);
    if (name.isEmpty) {
      _snack('Enter a name for the scan.');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => _saving = true);

    try {
      await widget.store.create(
        name: name,
        pagePaths: widget.pagePaths,
        format: _format,
        paper: _paper,
        brightness: _brightness,
        contrast: _contrast,
      );
      await widget.store.savePrefs(
        ExportPrefs(paperId: _paper.id, formatId: _format.id),
      );
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e, stack) {
      if (!mounted) return;
      setState(() => _saving = false);
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Could not save'),
          content: SingleChildScrollView(child: SelectableText('$e\n\n$stack')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final pageCount = widget.pagePaths.length;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop || _saving) return;
        if (await _confirmDiscard() && mounted) {
          Navigator.pop(context, false);
        }
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Export')),
        body: Column(
          children: [
            Expanded(
              flex: 5,
              child: PageView.builder(
                controller: _pages,
                itemCount: pageCount,
                onPageChanged: (i) => setState(() => _current = i),
                itemBuilder: (context, index) => _buildPreview(index),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                pageCount == 1
                    ? '1 page'
                    : 'Page ${_current + 1} of $pageCount  (swipe)',
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
            Expanded(
              flex: 6,
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: _buildSettings(),
              ),
            ),
          ],
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_alt),
              label: Text(_saving ? 'Saving...' : 'Save'),
            ),
          ),
        ),
      ),
    );
  }

  /// One page, shown as it will be placed on the chosen paper, with the
  /// brightness and contrast applied.
  Widget _buildPreview(int index) {
    return FutureBuilder<Size>(
      future: _sizeOf(index),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Center(child: Text('Could not load this page.'));
        }
        final size = snapshot.data;
        if (size == null) {
          return const Center(child: CircularProgressIndicator());
        }
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Center(
            child: AspectRatio(
              aspectRatio: pageAspect(_paper, size.width, size.height),
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  color: Colors.white,
                  boxShadow: [
                    BoxShadow(blurRadius: 8, color: Color(0x33000000)),
                  ],
                ),
                child: ColorFiltered(
                  colorFilter: ColorFilter.matrix(
                    previewMatrix(
                      brightness: _brightness,
                      contrast: _contrast,
                    ),
                  ),
                  child: Image.file(
                    File(widget.pagePaths[index]),
                    fit: BoxFit.contain,
                    cacheWidth: 1400,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSettings() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _name,
          enabled: !_saving,
          decoration: const InputDecoration(
            labelText: 'Name',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        DropdownMenu<PaperSize>(
          key: ValueKey('paper-${_paper.id}'),
          initialSelection: _paper,
          label: const Text('Paper size'),
          expandedInsets: EdgeInsets.zero,
          enabled: !_saving,
          dropdownMenuEntries: [
            for (final paper in paperSizes)
              DropdownMenuEntry<PaperSize>(value: paper, label: paper.label),
          ],
          onSelected: (paper) {
            if (paper != null) setState(() => _paper = paper);
          },
        ),
        const SizedBox(height: 12),
        SegmentedButton<OutputFormat>(
          segments: [
            for (final format in OutputFormat.values)
              ButtonSegment<OutputFormat>(
                value: format,
                label: Text(format.label),
              ),
          ],
          selected: {_format},
          onSelectionChanged:
              _saving ? null : (selection) => setState(() => _format = selection.first),
        ),
        if (_format != OutputFormat.pdf &&
            widget.pagePaths.length > 1) ...[
          const SizedBox(height: 4),
          Text(
            'Each page is saved as its own image.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        const SizedBox(height: 8),
        _SliderRow(
          label: 'Brightness',
          value: _brightness,
          min: -100,
          max: 100,
          divisions: 40,
          onChanged: _saving ? null : (v) => setState(() => _brightness = v),
        ),
        _SliderRow(
          label: 'Contrast',
          value: _contrast,
          min: -50,
          max: 100,
          divisions: 30,
          onChanged: _saving ? null : (v) => setState(() => _contrast = v),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: _saving || (_brightness == 0 && _contrast == 0)
                ? null
                : () => setState(() {
                      _brightness = 0;
                      _contrast = 0;
                    }),
            child: const Text('Reset'),
          ),
        ),
      ],
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: 84, child: Text(label)),
        Expanded(
          child: Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            label: value.round().toString(),
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 40,
          child: Text(
            value.round().toString(),
            textAlign: TextAlign.end,
          ),
        ),
      ],
    );
  }
}
