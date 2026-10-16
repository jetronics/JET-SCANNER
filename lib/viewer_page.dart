import 'package:flutter/material.dart';

import 'scan_store.dart';

/// Full-screen viewer for documents saved as images (PDFs open in the
/// phone's own PDF viewer). Swipe between pages, pinch to zoom.
class ViewerPage extends StatefulWidget {
  const ViewerPage({super.key, required this.item});

  final ScanItem item;

  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage> {
  int _current = 0;

  @override
  Widget build(BuildContext context) {
    final files = widget.item.files;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.item.name, overflow: TextOverflow.ellipsis),
        actions: [
          if (files.length > 1)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(child: Text('${_current + 1} / ${files.length}')),
            ),
        ],
      ),
      body: PageView.builder(
        itemCount: files.length,
        onPageChanged: (i) => setState(() => _current = i),
        itemBuilder: (context, index) => InteractiveViewer(
          maxScale: 6,
          child: Center(child: Image.file(files[index], fit: BoxFit.contain)),
        ),
      ),
    );
  }
}
