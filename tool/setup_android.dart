// Run once after `flutter create --platforms=android .`:
//
//   dart run tool/setup_android.dart
//
// - Sets the launcher name to "Doc Scanner".
// - Declares a <queries> entry so the app can find a PDF viewer on Android 11+.
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

  var xml = manifest.readAsStringSync();
  final original = xml;

  xml = xml.replaceFirst(
    RegExp(r'android:label="[^"]*"'),
    'android:label="Doc Scanner"',
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
