import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'scan_store.dart';
import 'settings.dart';

/// Preview and edit the pages of a scan: choose paper size and format, set
/// brightness and contrast (for all pages or one at a time), reorder or remove
/// pages, then save.
///
/// Used right after scanning ([editing] is null) and to edit a saved scan
/// again ([editing] is that scan, which is replaced on save). Pops with `true`
/// when something was saved.
class ExportPage extends StatefulWidget {
  const ExportPage({
    super.key,
    required this.pages,
    required this.store,
    this.editing,
  });

  final List<PageSpec> pages;
  final ScanStore store;
  final ScanItem? editing;

  @override
  State<ExportPage> createState() => _ExportPageState();
}

/// A page being edited. Mutable so the sliders can change it in place.
class _EditPage {
  _EditPage(this.path, this.brightness, this.contrast);

  final String path;
  double brightness;
  double contrast;
}

class _ExportPageState extends State<ExportPage> {
  late final TextEditingController _name = TextEditingController(
    text: widget.editing?.name ?? widget.store.defaultName(),
  );
  final PageController _pageController = PageController();
  final Map<String, Future<Size>> _sizes = {};

  late final List<_EditPage> _pages = [
    for (final p in widget.pages) _EditPage(p.path, p.brightness, p.contrast),
  ];
  late PaperSize _paper = paperById(widget.editing?.paperId);
  late OutputFormat _format = widget.editing?.format ?? OutputFormat.pdf;
  late bool _applyAll = _allSame();
  int _current = 0;
  bool _saving = false;
  bool _dirty = false;

  bool get _isNew => widget.editing == null;

  @override
  void initState() {
    super.initState();
    if (_isNew) _loadPrefs();
  }

  @override
  void dispose() {
    _name.dispose();
    _pageController.dispose();
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

  bool _allSame() {
    if (_pages.length < 2) return true;
    final first = _pages.first;
    return _pages.every(
      (p) => p.brightness == first.brightness && p.contrast == first.contrast,
    );
  }

  /// Pixel size of a page, read from the file header without decoding it.
  Future<Size> _sizeOf(String path) => _sizes.putIfAbsent(path, () async {
        final bytes = await File(path).readAsBytes();
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

  // ---- Editing -----------------------------------------------------------------

  void _setBrightness(double value) => setState(() {
        _dirty = true;
        if (_applyAll) {
          for (final p in _pages) {
            p.brightness = value;
          }
        } else {
          _pages[_current].brightness = value;
        }
      });

  void _setContrast(double value) => setState(() {
        _dirty = true;
        if (_applyAll) {
          for (final p in _pages) {
            p.contrast = value;
          }
        } else {
          _pages[_current].contrast = value;
        }
      });

  /// Switching on copies the current page's values to every page.
  void _toggleApplyAll(bool on) => setState(() {
        _applyAll = on;
        if (on) {
          final source = _pages[_current];
          for (final p in _pages) {
            p.brightness = source.brightness;
            p.contrast = source.contrast;
          }
          _dirty = true;
        }
      });

  void _resetAdjustments() => setState(() {
        _dirty = true;
        for (final p in _applyAll ? _pages : [_pages[_current]]) {
          p.brightness = 0;
          p.contrast = 0;
        }
      });

  void _showPage(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_pageController.hasClients) _pageController.jumpToPage(index);
    });
  }

  void _movePage(int delta) {
    final target = _current + delta;
    if (target < 0 || target >= _pages.length) return;
    setState(() {
      final page = _pages.removeAt(_current);
      _pages.insert(target, page);
      _current = target;
      _dirty = true;
    });
    _showPage(target);
  }

  void _removePage() {
    if (_pages.length < 2) return;
    setState(() {
      _pages.removeAt(_current);
      if (_current >= _pages.length) _current = _pages.length - 1;
      _dirty = true;
    });
    _showPage(_current);
    _snack('Page removed. It is gone for good once you save.');
  }

  // ---- Leaving and saving ---------------------------------------------------------

  Future<bool> _confirmDiscard() async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_isNew ? 'Discard this scan?' : 'Discard your changes?'),
        content: Text(
          _isNew
              ? 'The scanned pages have not been saved yet.'
              : 'Your changes to this scan have not been saved.',
        ),
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
      await widget.store.save(
        name: name,
        pages: [
          for (final p in _pages)
            PageSpec(p.path, brightness: p.brightness, contrast: p.contrast),
        ],
        format: _format,
        paper: _paper,
        replacing: widget.editing,
      );
      if (_isNew) {
        await widget.store.savePrefs(
          ExportPrefs(paperId: _paper.id, formatId: _format.id),
        );
      }
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

  // ---- UI ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop || _saving) return;
        if (!_isNew && !_dirty) {
          Navigator.pop(context, false);
          return;
        }
        if (await _confirmDiscard() && mounted) {
          Navigator.pop(context, false);
        }
      },
      child: Scaffold(
        appBar: AppBar(title: Text(_isNew ? 'Export' : 'Edit scan')),
        body: Column(
          children: [
            Expanded(
              flex: 5,
              child: PageView.builder(
                controller: _pageController,
                itemCount: _pages.length,
                onPageChanged: (i) => setState(() => _current = i),
                itemBuilder: (context, index) => _buildPreview(_pages[index]),
              ),
            ),
            _buildPageBar(),
            Expanded(
              flex: 6,
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
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

  /// Page counter, with move and remove buttons when there are several pages.
  Widget _buildPageBar() {
    final count = _pages.length;
    final style = Theme.of(context).textTheme.labelMedium;
    if (count == 1) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text('1 page', style: style),
      );
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          tooltip: 'Move page earlier',
          onPressed: _saving || _current == 0 ? null : () => _movePage(-1),
          icon: const Icon(Icons.chevron_left),
        ),
        Text('Page ${_current + 1} of $count', style: style),
        IconButton(
          tooltip: 'Move page later',
          onPressed:
              _saving || _current >= count - 1 ? null : () => _movePage(1),
          icon: const Icon(Icons.chevron_right),
        ),
        const SizedBox(width: 16),
        IconButton(
          tooltip: 'Remove this page',
          onPressed: _saving ? null : _removePage,
          icon: const Icon(Icons.delete_outline),
        ),
      ],
    );
  }

  /// One page, shown as it will be placed on the chosen paper, with its
  /// brightness and contrast applied.
  Widget _buildPreview(_EditPage page) {
    return FutureBuilder<Size>(
      key: ValueKey(page.path),
      future: _sizeOf(page.path),
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
                      brightness: page.brightness,
                      contrast: page.contrast,
                    ),
                  ),
                  child: Image.file(
                    File(page.path),
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
    final page = _pages[_current];
    final hasAdjustments = _applyAll
        ? _pages.any((p) => p.brightness != 0 || p.contrast != 0)
        : (page.brightness != 0 || page.contrast != 0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _name,
          enabled: !_saving,
          onChanged: (_) => _dirty = true,
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
            if (paper != null) {
              setState(() {
                _paper = paper;
                _dirty = true;
              });
            }
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
          onSelectionChanged: _saving
              ? null
              : (selection) => setState(() {
                    _format = selection.first;
                    _dirty = true;
                  }),
        ),
        if (_format != OutputFormat.pdf && _pages.length > 1) ...[
          const SizedBox(height: 4),
          Text(
            'Each page is saved as its own image.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        const SizedBox(height: 8),
        if (_pages.length > 1)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Same brightness and contrast on every page'),
            value: _applyAll,
            onChanged: _saving ? null : _toggleApplyAll,
          ),
        _SliderRow(
          label: 'Brightness',
          value: page.brightness,
          min: -100,
          max: 100,
          divisions: 40,
          onChanged: _saving ? null : _setBrightness,
        ),
        _SliderRow(
          label: 'Contrast',
          value: page.contrast,
          min: -50,
          max: 100,
          divisions: 30,
          onChanged: _saving ? null : _setContrast,
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: _saving || !hasAdjustments ? null : _resetAdjustments,
            child: Text(_applyAll ? 'Reset' : 'Reset this page'),
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
