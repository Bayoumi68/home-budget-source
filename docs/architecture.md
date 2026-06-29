# Architecture

A client-side Flutter app over Firebase. Code in `lib/` is organized in three layers.

## Layers

- **screens/** — UI. Key screens: splash, auth, chat (the main logging surface), analytics,
  members, teams, team_member_home, group_settings, notifications.
- **providers/** — app state via `ChangeNotifier`: auth, budget, chat, notification, theme.
- **services/** — integrations and logic: `auth_service` (Firebase Auth), `database_service`
  (Firestore reads/writes), `ai_service` (offline Arabic parser), `voice_service`
  (speech-to-text input), `local_notice_service` (with `_web` / `_stub` variants).

## Data model (Firestore)

- `families/{groupId}` with subcollections: `members`, `messages`, `transactions`, `budgets`,
  `categories`, `learnedKeywords`, `wallets`, `teams`, `notifications`.
- Top-level: `inviteCodes`, `familyNames` (family-name uniqueness lock), `diagnostics`.
- Collection-group queries (`members.phone`, `members.authUid`, `teams.memberIds`) back join
  and session-restore; their indexes live in `firestore.indexes.json`, access rules in
  `firestore.rules`.

## Offline Arabic parser (`ai_service.dart`)

The "AI" is **not an API or ML model** — it is a deterministic, fully offline rule/keyword
parser. Per message it:

1. **Extracts the amount** — currency-anchored; skips quantities/units so "2 كيلو" isn't read
   as the price.
2. **Detects the category** — score-based keyword matching with edit-distance (Levenshtein)
   tolerance for typos.
3. **Classifies income vs expense** — keyword signals; refunds count as income.

**Learning loop:** correcting a transaction's category (long-press → change type) stores that
message's words → category in the `learnedKeywords` collection; later parses consult learned
keywords first. The app adapts per family with no server and no model.

## Categories

19 expense + 5 income categories with emoji icons, defined in `lib/config/constants.dart`.

## See also

- [Overview](overview.md)
- [Authentication & Family Model](auth-and-family-model.md)
- [Development & Deployment](dev-and-deploy.md)
