---
name: dev-environment
description: "Home Budget toolchain, Firebase project, GitHub repos, and build/deploy/APK gotchas"
metadata: 
  node_type: memory
  type: project
  originSessionId: 5e670845-0177-4933-8e31-683257188133
---

Set up 2026-06-28 to build, run, and distribute Home Budget locally.

**Toolchain (all installed this session; the Claude tool shells do NOT inherit the updated user PATH — invoke with full paths and prepend the bin dirs):**
- Flutter 3.44.4 stable → `C:\Users\user\flutter\bin\flutter.bat` (Dart at `…\flutter\bin\dart.bat`).
- JDK 21 → `C:\Users\user\jdk21\jdk-21.0.11+10` (set `JAVA_HOME` for Android builds).
- Android SDK → `C:\Users\user\Android\Sdk` (build-tools 36, platform-tools, platform android-36, NDK 28.2.13676358). aapt at `…\build-tools\36.0.0\aapt.exe`.
- Node 20 → `E:\Nodes\node-v20.20.2-win-x64`; Firebase CLI 15.x (`firebase.cmd` there); flutterfire_cli (pub global bin `C:\Users\user\AppData\Local\Pub\Cache\bin`).
- GitHub CLI 2.95 → `C:\Users\user\gh\bin\gh.exe` (authed as **Bayoumi68**).

**Firebase project:** the user's own **`budget-home-bayoumi`** (project number 229990261595). Linked via `flutterfire configure` (regenerates firebase_options.dart + google-services.json). Web live at https://budget-home-bayoumi.web.app.

**GitHub repos (two, separate):**
- **Source:** https://github.com/Bayoumi68/home-budget-source — **PRIVATE**. Pushed via remote **`mine`** (origin still = read-only Mokamal10/budget-home-source). `git push mine main`.
- **APK hosting:** https://github.com/Bayoumi68/home-budget-apk — public. Release tag **v2**, asset always named **`home-budget.apk`**, served via the **stable** URL `releases/latest/download/home-budget.apk` (don't version the filename — the link must not change). Public download page: `budget-home-bayoumi.web.app/download.html` redirects there.

**Run/build:**
- Web (no SIM needed): `flutter run -d edge --web-port=5599` (Edge is the only browser Flutter detects; Chrome not installed). `flutter build web --release` → `firebase deploy --only hosting`.
- APK: `flutter build apk --release` → copy app-release.apk to home-budget.apk → `gh release upload v2 home-budget.apk --clobber`.

**Gotchas (all real, all hit):**
1. **Cross-drive Kotlin build crash** — pub cache is on C:, project on E:; Kotlin's incremental compiler can't relativize across Windows drive roots → set `kotlin.incremental=false` in `android/gradle.properties` (done).
2. **Firebase Spark plan forbids hosting executables** → can't host the APK on Firebase Hosting; use GitHub Releases.
3. **APK size:** `flutter build apk` makes a **universal** APK (~53MB, three ABIs). The old one was arm64-only (~20MB). Use `--split-per-abi` if a smaller arm64 build is wanted.
4. **minSdk 24** (Android 7+); Firebase floor is 23. Lower only if someone has Android 6.
5. Firestore: collection-group queries (`members.phone`, `members.authUid`, `teams.memberIds`) need indexes in `firestore.indexes.json`; rules are beta-grade (wide-open by groupId) + `familyNames` lock + collection-group read rules.

See [[auth-verification-approach]], [[budget-home-overview]].
