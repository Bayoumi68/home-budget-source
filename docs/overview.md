# Home Budget — Overview

Home Budget is an Arabic-first, chat-driven budgeting app for families. Members log
spending in everyday Arabic — typed or spoken — and the app turns each message into a
categorized transaction, then rolls spending up into budgets and analytics.

The model is **allowance-style**: the family **admin** holds cash wallets and **funds each
member's wallet**; members **spend only from their own wallet** and see only their own data,
while the admin funds, withdraws, messages members, and monitors everyone. See
[Architecture](architecture.md) for the wallet/ledger model.

## Stack

- **Front end:** Flutter (Dart), Arabic-first RTL UI.
- **Back end:** Firebase — Cloud Firestore (data), Firebase Auth (login), Firebase Hosting
  (web build). There is no custom server; all logic runs client-side against Firebase.
- **Project / package name:** `budget_home` (Android applicationId `com.example.budget_home`).

## How it works, in one line

A member writes "دفعت ٢٥٠ سوبر ماركت" → an offline parser extracts the amount and category →
a transaction is stored under the family → budgets and analytics update.

The chat is **intent-first** — the verb decides the action, not the number. Beyond expenses,
the admin types or speaks commands like «أضف ٢٠٠ لمحمد» (fund), «اسحب ١٠٠ من أحمد» (withdraw),
«حوّل ٥٠٠ من الكاش إلى البنك» (transfer), «رفع حد محمد ٢٠٠٠» (set limit) — each confirms first.

## Defaults

Arabic language, currency EGP, up to 10 members per family.

## Distribution

- Web app: https://home-budgets.web.app (primary) — also https://budget-home-bayoumi.web.app.
  Note: web Google sign-in works on desktop Chrome / Samsung Browser but not Chrome-on-Android
  — on phones use the APK. See [Authentication & Family Model](auth-and-family-model.md).
- Android APK: stable link via GitHub Releases (see [Development & Deployment](dev-and-deploy.md)).

## See also

- [Architecture](architecture.md)
- [Authentication & Family Model](auth-and-family-model.md)
- [Development & Deployment](dev-and-deploy.md)
