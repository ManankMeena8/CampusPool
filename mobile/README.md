# CampusPool mobile

Flutter app for CampusPool (Android only). Riverpod, dio, go_router, flutter_map with
OpenStreetMap, Firebase Cloud Messaging.

## First-time setup

### 1. Firebase config (`google-services.json`)

The Android build needs `android/app/google-services.json`, and the Google Services Gradle
plugin fails the build without it. The file is gitignored: every developer downloads their own.

1. In the [Firebase console](https://console.firebase.google.com/), open the CampusPool
   project (or create one) and add an **Android app** with the package name
   `com.campuspool.campuspool`. It must match `applicationId` in
   `android/app/build.gradle.kts`.
2. Download `google-services.json` and put it at `mobile/android/app/google-services.json`.
3. Check that git ignores it: `git check-ignore -v android/app/google-services.json`.

The backend sends the pushes with its own service account key
(`FIREBASE_SERVICE_ACCOUNT_PATH`, see `backend/README.md`). It must come from the same
Firebase project.

If Firebase can't start on the device, the app still runs and only push notifications are off
(the log says "Push notifications off").

### 2. Release signing (only for release APKs)

The keystore lives **outside the repo**. Create it once, and back up the file and its password:
without them you can't ship an update that installs over the app.

```powershell
New-Item -ItemType Directory -Force C:\secrets | Out-Null
& "C:\Program Files\Android\Android Studio\jbr\bin\keytool.exe" -genkeypair -v `
  -keystore C:\secrets\campuspool-release.jks -storetype PKCS12 `
  -keyalg RSA -keysize 2048 -validity 10000 -alias campuspool
```

Then copy `android/key.properties.example` to `android/key.properties` (gitignored) and fill in
the passwords. For a PKCS12 keystore, `keyPassword` is the same as `storePassword`.

Without `key.properties` the release build is signed with the debug key, and Gradle prints a
warning. If `key.properties` points to a keystore that doesn't exist, the build fails.

## Run (debug)

```sh
flutter pub get
flutter run                     # emulator: the API at http://10.0.2.2:3000 (the host's port 3000)
flutter run --dart-define=API_BASE_URL=http://192.168.1.20:3000   # a phone on the same Wi-Fi
```

## Build settings (`--dart-define`)

| Name | Default | Rules |
| --- | --- | --- |
| `APP_ENV` | `dev` | `dev` or `prod`; anything else is refused |
| `API_BASE_URL` | `http://10.0.2.2:3000`, debug builds only | Required in a release build and whenever `APP_ENV=prod`. `prod` requires `https://` |
| `ALLOWED_EMAIL_DOMAIN` | `nsut.ac.in` | Must match the backend's `ALLOWED_EMAIL_DOMAIN` |

No production URL is hardcoded. A build that breaks these rules opens a "misconfigured" screen
with the reason, instead of failing on every request.

## Release APK

```sh
flutter build apk --release --dart-define=APP_ENV=prod --dart-define=API_BASE_URL=https://<api host>
```

The APK is written to `build/app/outputs/flutter-apk/app-release.apk`. To check which key
signed it:

```sh
apksigner verify --print-certs build/app/outputs/flutter-apk/app-release.apk
```

The deployed Render URL goes in `API_BASE_URL` once the backend is deployed. Until then,
`https://api.campuspool.invalid` (a reserved name that never resolves) builds an APK that
starts but can't reach a server, which is enough to check that the release build works.

## Tests

```sh
flutter analyze
flutter test
```

`test/small_screens_test.dart` renders every main screen on a 320 × 568 dp phone with 1.3×
text. Keep it passing when adding screens.

## Replacing the launcher icon

The current icon is drawn by hand as vectors:

- `android/app/src/main/res/drawable/ic_launcher_foreground.xml`
- `android/app/src/main/res/drawable/ic_launcher_monochrome.xml` (Android 13+ themed icon)
- `android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml` (adaptive icon, Android 8+)
- `android/app/src/main/res/mipmap-*dpi/ic_launcher.png` (Android 7)

To replace it with a logo using [flutter_launcher_icons](https://pub.dev/packages/flutter_launcher_icons):

1. Make two 1024 × 1024 PNGs: `assets/icon/icon.png` (the full icon) and
   `assets/icon/foreground.png` (the logo alone on transparent, inside the middle 66%).
2. Add it as a dev dependency and configure it in `pubspec.yaml`:

   ```yaml
   dev_dependencies:
     flutter_launcher_icons: ^0.14.0

   flutter_launcher_icons:
     android: true
     ios: false
     image_path: assets/icon/icon.png
     adaptive_icon_background: "#1E6FD9"
     adaptive_icon_foreground: assets/icon/foreground.png
     min_sdk_android: 24
   ```

3. Delete the three XML files listed above, so the old vectors can't win over the new
   images, then run `dart run flutter_launcher_icons`.
4. For an Android 13+ themed icon, also set `adaptive_icon_monochrome` to a single-colour
   PNG.

The notification icon (`res/drawable/ic_notification.xml`, a white car) is separate. It must
stay a white shape on transparent.
