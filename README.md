# Home Budget

An Arabic-first, chat-driven budgeting app for families. Members log spending in everyday
Arabic — typed or spoken — and the app turns each message into a categorized transaction, then
rolls spending up into shared budgets and analytics for the whole family.

Built with **Flutter** (Dart) on **Firebase** (Cloud Firestore, Auth, Hosting). There is no
custom server; all logic runs client-side. The category parser is a fully offline Arabic
rule/keyword engine — no API, no ML model.

- **Web app:** https://budget-home-bayoumi.web.app
- **Android APK:** https://github.com/Bayoumi68/home-budget-apk/releases/latest/download/home-budget.apk

## Quick start

```bash
flutter pub get
```

Then, to run on a connected phone (recommended):

- **Windows:** double-click `run.bat`, or run `setup.ps1` for a guided first-time setup.
- Both detect the device via `adb` and run `flutter run -d <serial>`. If no phone is found
  they print the USB-debugging steps instead of launching on the PC/web.

To run the web build: `flutter run -d edge --web-port=5599`.

## Documentation

Full project documentation lives in [`docs/`](docs/README.md):

- [Overview](docs/overview.md) — what the app is, the stack, how it works.
- [Architecture](docs/architecture.md) — Flutter layers, the Firestore data model, the offline
  Arabic parser.
- [Authentication & Family Model](docs/auth-and-family-model.md) — login, family identity,
  create vs. join, session restore.
- [Development & Deployment](docs/dev-and-deploy.md) — toolchain, Firebase, repositories,
  build/run/deploy.
