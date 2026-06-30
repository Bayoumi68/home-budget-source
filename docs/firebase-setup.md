# Firebase Setup — point the app at YOUR own project

This is the anchor reference for wiring Home Budget to a fresh Firebase project. Everything here
is project-specific; replace it and the app runs entirely on your own backend (no other server).

## 1. What is project-specific (the values to replace)

| File | Holds | How to set it |
|------|-------|---------------|
| `.firebaserc` | default project id (`budget-home-bayoumi`) | `firebase use --add` or edit it to your project id |
| `firebase.json` → `hosting[].site` | Hosting site IDs (`budget-home-bayoumi`, `home-budgets`) | your Hosting site ID(s); drop to one entry if you want one site |
| `firebase.json` → `flutter.platforms` | projectId + appIds | rewritten by `flutterfire configure` |
| `lib/firebase_options.dart` | apiKey, appId, projectId, **authDomain**, storageBucket, messagingSenderId, measurementId | **regenerate** with `flutterfire configure` (don't hand-edit) |
| `android/app/google-services.json` | Android Firebase config | written by `flutterfire configure` / downloaded from console — **gitignored**, never committed |
| `lib/config/constants.dart` | `appWebLink`, `androidDownloadLink` | your web URL + your APK download link |
| `android/key.properties` + `android/app/*.jks` | release signing | create your own keystore — **gitignored** (see `android/key.properties.example`) |

> `lib/firebase_options.dart` is committed in this repo for convenience, but it's just generated
> output — overwrite it with your own via `flutterfire configure`.

## 2. Create the Firebase project + services

In the [Firebase console](https://console.firebase.google.com): create a project, then enable
- **Firestore Database** (production mode — rules are deployed from this repo),
- **Authentication** → sign-in methods: **Google** and **Email/Password**,
- **Hosting** (create a site; create a second one only if you want two URLs like this repo does).

## 3. Tooling

- Flutter SDK, **Firebase CLI** (`npm i -g firebase-tools`), **FlutterFire CLI**
  (`dart pub global activate flutterfire_cli`).
- `firebase login`.

## 4. Generate config

```bash
flutterfire configure        # pick your project + platforms (android, web)
firebase use --add           # set your project as default (.firebaserc)
```

This rewrites `lib/firebase_options.dart`, `android/app/google-services.json`, and the `flutter`
block in `firebase.json`.

⚠️ **Keep the default `authDomain` = `<your-project>.firebaseapp.com`.** Google handles that
domain for sign-in across browsers; switching it to a custom `*.web.app` domain breaks Google
sign-in in Chrome-on-Android (see [Authentication & Family Model](auth-and-family-model.md)).
`flutterfire configure` already sets the `firebaseapp.com` value — don't change it.

## 5. Deploy Firestore rules + indexes

```bash
firebase deploy --only firestore
```

(`firestore.rules` and `firestore.indexes.json` are in this repo — the `members.phone`,
`members.authUid`, `members.email`, and `teams.memberIds` collection-group indexes are required
for join / session-restore.)

## 6. Auth console wiring

- **Android Google sign-in:** add your app's signing **SHA-1 + SHA-256** in
  console → Project settings → your Android app → *Add fingerprint*. Use the **debug** cert for
  local runs and the **release** cert before distributing. Get them with
  `cd android && ./gradlew signingReport` (or `keytool -list -v -keystore <file>`).
- **Web Google sign-in:** in Google Cloud Console → APIs & Services → Credentials → the
  auto-created **Web client**, add **Authorized JavaScript origins** (your Hosting URLs +
  `http://localhost:5000` for dev) and the **redirect URI**
  `https://<your-project>.firebaseapp.com/__/auth/handler`. Missing the redirect URI →
  "access blocked / redirect_uri_mismatch".

## 7. App-facing URLs

Edit `lib/config/constants.dart`:
- `appWebLink` → your deployed web URL.
- `androidDownloadLink` → your APK download page/link (and update the GitHub link inside
  `web/download.html` if you host the APK on your own GitHub Releases).

## 8. Release signing (only to ship an APK)

Create a keystore, then `android/key.properties` (gitignored):

```
storePassword=…
keyPassword=…
keyAlias=…
storeFile=release-keystore.jks
```

A template is in `android/key.properties.example`. Without it, release builds fall back to the
debug key (fine for testing, not for distribution).

## 9. Build & run

```bash
flutter pub get
flutter run -d chrome              # or a connected device
flutter build web --release && firebase deploy --only hosting
flutter build apk --release       # signed with your release key if key.properties exists
```

## See also

- [Overview](overview.md) · [Architecture](architecture.md) ·
  [Authentication & Family Model](auth-and-family-model.md) ·
  [Development & Deployment](dev-and-deploy.md)
