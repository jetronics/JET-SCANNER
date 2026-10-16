// Run once after `flutter create --platforms=android .`:
//
//   dart run tool/setup_android.dart
//
// - Sets the launcher name to "Jet Scanner".
// - Installs the app icon (tool/android_res -> android/app/src/main/res).
// - Declares a <queries> entry so the app can find a PDF viewer on Android 11+.
// - Turns off R8 code shrinking for release builds. With shrinking on, the
//   release APK crashed with a NullPointerException as soon as the scanner
//   started, while the debug APK (no shrinking) worked.
//
// Safe to run more than once.
import 'dart:io';

void main() {
  final manifest = File('android/app/src/main/AndroidManifest.xml');
  if (!manifest.existsSync()) {
    stderr.writeln(
      'android/app/src/main/AndroidManifest.xml not found.\n'
      'Run "flutter create --platforms=android ." in the project root first.',
    );
    exit(1);
  }

  _configureManifest(manifest);
  _installIcons();
  _disableShrinking();
}

void _configureManifest(File manifest) {
  var xml = manifest.readAsStringSync();
  final original = xml;

  xml = xml.replaceFirst(
    RegExp(r'android:label="[^"]*"'),
    'android:label="Jet Scanner"',
  );

  if (!xml.contains('application/pdf')) {
    const viewIntent = '''
        <intent>
            <action android:name="android.intent.action.VIEW"/>
            <data android:mimeType="application/pdf"/>
        </intent>
''';
    if (xml.contains('</queries>')) {
      xml = xml.replaceFirst('</queries>', '$viewIntent    </queries>');
    } else {
      xml = xml.replaceFirst(
        '</manifest>',
        '    <queries>\n$viewIntent    </queries>\n</manifest>',
      );
    }
  }

  if (xml == original) {
    stdout.writeln('AndroidManifest.xml already configured.');
    return;
  }
  manifest.writeAsStringSync(xml);
  stdout.writeln('AndroidManifest.xml updated.');
}

void _installIcons() {
  final source = Directory('tool/android_res');
  if (!source.existsSync()) {
    stderr.writeln('warning: tool/android_res not found, keeping default icon.');
    return;
  }

  final sourcePath = source.absolute.path;
  var copied = 0;
  for (final entity in source.listSync(recursive: true)) {
    if (entity is! File) continue;
    final relative = entity.absolute.path.substring(sourcePath.length + 1);
    final target = File('android/app/src/main/res/$relative');
    target.parent.createSync(recursive: true);
    entity.copySync(target.path);
    copied++;
  }
  stdout.writeln('Installed $copied icon files.');
}

void _disableShrinking() {
  final kts = File('android/app/build.gradle.kts');
  final groovy = File('android/app/build.gradle');
  final file = kts.existsSync() ? kts : (groovy.existsSync() ? groovy : null);
  if (file == null) {
    stderr.writeln('warning: android/app/build.gradle(.kts) not found.');
    return;
  }

  var text = file.readAsStringSync();
  if (text.contains('isMinifyEnabled') || text.contains('minifyEnabled')) {
    stdout.writeln('Shrinking already configured in ${file.path}.');
    return;
  }

  final isKotlin = file.path.endsWith('.kts');
  final lines = isKotlin
      ? '            isMinifyEnabled = false\n'
          '            isShrinkResources = false\n'
      : '            minifyEnabled false\n'
          '            shrinkResources false\n';

  // The "release {" line inside buildTypes.
  final releaseBlock = RegExp(r'release\s*\{[^\n]*\n');
  if (!releaseBlock.hasMatch(text)) {
    stderr.writeln(
      'warning: could not find the release block in ${file.path}; '
      'release builds may crash when the scanner opens.',
    );
    return;
  }

  text = text.replaceFirstMapped(releaseBlock, (m) => '${m[0]}$lines');
  file.writeAsStringSync(text);
  stdout.writeln('Disabled code shrinking for release builds in ${file.path}.');
}
