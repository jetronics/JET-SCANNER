# Doc Scanner

An Android document scanner built with Flutter. Capture a page with the camera (or import from the gallery), let the scanner detect the edges and clean it up, and save multi-page scans as PDFs.

The capture screen is Google's ML Kit Document Scanner, so edge detection, perspective correction, rotation and filters come built in.

## Features

- Camera capture and gallery import
- Automatic edge detection, crop and perspective correction
- Filters (color, grayscale, black and white, shadow cleanup)
- Multi-page scans (up to 30 pages) saved as one PDF
- Library of saved scans with thumbnails: open, share, rename, delete

## Requirements

- Android 5.0 (API 21) or newer
- Google Play services on the phone (the scanner UI is delivered through it, so the app needs no camera permission of its own)

## Build the APK

### Option A: GitHub Actions (nothing to install)

1. Push this repository to GitHub on the `main` branch.
2. Open the **Actions** tab and wait for the **Build APK** run (or start it with **Run workflow**).
3. Open the finished run and download the `doc-scanner-apk` artifact. Unzip it to get `app-release.apk`.

### Option B: on your computer

Install the stable [Flutter SDK](https://docs.flutter.dev/get-started/install) and Android Studio (for the Android SDK), then from the project folder:

```bash
flutter create --platforms=android --project-name doc_scanner --org com.yourname .
dart run tool/setup_android.dart
flutter pub get
flutter run                    # run on a connected phone or emulator
flutter build apk --release    # build/app/outputs/flutter-apk/app-release.apk
```

`flutter create` generates the `android/` folder and leaves `lib/` and `pubspec.yaml` alone. `tool/setup_android.dart` sets the launcher name and lets the app find a PDF viewer. Both are safe to run again.

## Install on a phone

Copy `app-release.apk` to the phone, open it, and allow "Install unknown apps" for the app you opened it from.

## Notes

- The release APK is signed with the debug key, which is fine for personal use. Publishing to Google Play needs your own keystore.
- Scans live in the app's private storage, so uninstalling the app deletes them. Use Share to keep a copy elsewhere.
- If Gradle complains about the Java version, change `java-version` in `.github/workflows/build-apk.yml` or install a matching JDK locally.

## Ideas for later

- OCR so PDFs are searchable (`google_mlkit_text_recognition`)
- Merge and split PDFs
- Export to the Downloads folder
- Custom app icon
