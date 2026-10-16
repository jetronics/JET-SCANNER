import 'package:flutter/material.dart';

import 'home_page.dart';

void main() {
  runApp(const JetScannerApp());
}

class JetScannerApp extends StatelessWidget {
  const JetScannerApp({super.key});

  // The blue of the app icon.
  static const Color _seed = Color(0xFF0047D3);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Jet Scanner',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: _seed),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: _seed,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}
