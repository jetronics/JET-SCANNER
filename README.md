# Jet Scanner

An Android document scanner built with Flutter. Capture a page with the camera (or import from the gallery), let the scanner detect the edges and clean it up, then choose the paper size, brightness, contrast and file type before saving.

The capture screen is Google's ML Kit Document Scanner, so edge detection, perspective correction and rotation come built in. Everything after that (export settings, PDF/image creation, the library) is this app.

## Features

- Camera capture and gallery import, up to 30 pages per scan
- Automatic edge detection, crop and perspective correction
- **Export screen** after every scan, with a live preview of each page:
  - **Paper size:** Original (as scanned), A4, A5, A3, Letter, Legal, Long bond (8.5 × 13 in)
  - **Format:** PDF (all pages in one file), JPEG or PNG (one image per page)
  - **Brightness and contrast** sliders, applied to the saved file exactly as previewed
  - The last paper size and format you used are remembered
- Library of saved scans with thumbnails: open, share, rename, delete

Landscape scans get a landscape page, portrait scans a portrait page. Pages are centred on the paper on a white background and are never distorted.

## Requirements

- Android 5.0 (API 21) or newer
- Google Play services on the phone (the scanner screen is delivered through it, so the app needs no camera permission of its own)

## Build the APK

### Option A: GitHub Actions (nothing to install)

1. Push this repository to GitHub on the `main` branch.
2. Open the **Actions** tab and wait for the **Build APK** run (or start it with **Run workflow**).
3. Open the finished run and download the `doc-scanner-apk` artifact. Unzip it to get `app-release.apk`.

The run also produces `doc-scanner-debug-apk` (a debug build, handy for diagnosing problems). A failing unit test appears as a warning on the run but does not stop the APK from being built.

### Option B: on your computer

Install the stable [Flutter SDK](https://docs.flutter.dev/get-started/install) and Android Studio (for the Android SDK), then from the project folder:

```bash
flutter create --platforms=android --project-name doc_scanner --org com.yourname .
dart run tool/setup_android.dart
flutter pub get
flutter run                    # run on a connected phone or emulator
flutter build apk --release    # build/app/outputs/flutter-apk/app-release.apk
```

`flutter create` generates the `android/` folder and leaves `lib/` and `pubspec.yaml` alone. `tool/setup_android.dart` then:

- sets the launcher name to "Jet Scanner" and installs the app icon,
- lets the app find a PDF viewer,
- turns off code shrinking (R8) for release builds. With shrinking on, the release APK failed with a `NullPointerException` the moment the scanner opened.

Both steps are safe to run again.

## App icon

The icon is built from `tool/icon/jet-scanner-logo.png`. To change it, replace that file and run:

```bash
pip install pillow numpy scipy
python3 tool/make_icons.py
```

This regenerates the files in `tool/android_res/`, which `setup_android.dart` copies into the Android project.

## Install on a phone

Copy `app-release.apk` to the phone, open it, and allow "Install unknown apps" for the app you opened it from.

## Notes

- The release APK is signed with the debug key, which is fine for personal use. Publishing to Google Play needs your own keystore.
- Scans live in the app's private storage, so uninstalling the app deletes them. Use Share to keep a copy elsewhere.
- Scans saved by the first version of the app are moved into the new library layout automatically.
- If Gradle complains about the Java version, change `java-version` in `.github/workflows/build-apk.yml` or install a matching JDK locally.

## Ideas for later

- OCR so PDFs are searchable (`google_mlkit_text_recognition`)
- Save JPEG/PNG straight to the phone gallery or Downloads folder
- Merge and split PDFs, reorder or delete individual pages
- Standalone camera and crop screen (no Google Play services needed)
