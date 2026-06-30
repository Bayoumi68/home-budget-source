# Development & Deployment

## Firebase project

`budget-home-bayoumi` (project number 229990261595, **unrenameable**). A **single** Hosting site
serves `build/web` (see the array in `firebase.json`):
- **https://home-budgets.web.app** — the one unified domain (web app + invite/download links).

(The project once also deployed to `budget-home-bayoumi.web.app`; that second site was dropped
from `firebase.json` to keep one domain. The site still exists in the console but is no longer
deployed to.) Web `authDomain` is
the Firebase default **`budget-home-bayoumi.firebaseapp.com`** — Google handles it for sign-in
across browsers (a custom `home-budgets.web.app` authDomain broke Chrome-on-Android; see the
[auth doc](auth-and-family-model.md)). The OAuth web client must authorize the app origins
(Authorized JavaScript origins) + the handler redirect URI `…firebaseapp.com/__/auth/handler`.
`flutterfire configure` rewrites `authDomain` — re-apply this value afterward. The **release
APK** is signed with
`android/app/release-keystore.jks` (password in `android/key.properties`, both gitignored — back
them up).

## Repositories

- **Source (public):** https://github.com/Bayoumi68/home-budget-source — pushed via the
  remote `mine` (`git push mine main`); `origin` stays the upstream read-only clone source.
- **APK hosting (public):** https://github.com/Bayoumi68/home-budget-apk — release tag `v2`,
  asset always named `home-budget.apk`, served from the **stable** URL
  `releases/latest/download/home-budget.apk` (the filename must not change so the link stays
  stable). `download.html` redirects there.

## Toolchain

Installed under the user profile, not on the global PATH — invoke with full paths from
automation:

- Flutter 3.44.4 — `C:\Users\user\flutter\bin` (Dart bundled).
- JDK 21 — `C:\Users\user\jdk21\jdk-21.0.11+10` (set `JAVA_HOME` for Android builds).
- Android SDK — `C:\Users\user\Android\Sdk` (build-tools 36, platform-tools, android-36,
  NDK 28.2.13676358).
- Node 20 — `E:\Nodes\node-v20.20.2-win-x64` + Firebase CLI 15; flutterfire_cli.
- GitHub CLI — authenticated as **Bayoumi68**.

## Build & run

- **Phone (preferred):** `run.bat` or `setup.ps1` — both detect the connected device via `adb`
  and run `flutter run -d <serial>`; if no device is found they print the USB-debugging steps
  and stop (they never silently launch on the PC or web).
- **Web:** `flutter run -d edge --web-port=5599`; release: `flutter build web --release` →
  `firebase deploy --only hosting`.
- **APK:** `flutter build apk --release` → copy to `home-budget.apk` →
  `gh release upload v2 home-budget.apk --clobber`.

## Known constraints

- **Cross-drive Kotlin build crash** — the pub cache is on C: and the project on E:; the Kotlin
  incremental compiler can't relativize paths across drive roots. Fixed by
  `kotlin.incremental=false` in `android/gradle.properties`.
- **Firebase Spark plan can't host executables** → the APK lives on GitHub Releases, not
  Firebase Hosting.
- **APK size** — the default build is a universal APK (~53 MB, three ABIs). Use
  `--split-per-abi` for a smaller (~20 MB) arm64 build.
- **minSdk 24** (Android 7+); the Firebase floor is 23.

## See also

- [Firebase Setup](firebase-setup.md) — wire the app to your own Firebase project
- [Overview](overview.md)
- [Architecture](architecture.md)
- [Authentication & Family Model](auth-and-family-model.md)
