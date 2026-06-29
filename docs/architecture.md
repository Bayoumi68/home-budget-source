# Architecture

A client-side Flutter app over Firebase. Code in `lib/` is organized in three layers.

## Layers

- **screens/** — UI. Key screens: splash, auth, chat (the main logging surface), analytics
  (reports), members, member_detail (admin's per-member view), teams, group_settings,
  notifications.
- **providers/** — app state via `ChangeNotifier`: auth, budget, chat, notification, theme.
- **services/** — integrations and logic: `auth_service` (Firebase Auth), `database_service`
  (Firestore reads/writes), `ai_service` (offline Arabic parser), `voice_service`
  (speech-to-text input), `local_notice_service` (with `_web` / `_stub` variants).

## Money model (the core domain)

Two independent axes — **people** and **accounts**:

- **People** = family members (each logs in). One is the **admin** (family leader).
- **Accounts = wallets** (cash containers). Ownership: the **admin owns one or more cash
  wallets** (كاش/بنك); **each member owns exactly one wallet** (their pocket,
  auto-provisioned). A wallet has a balance and a **DR/CR ledger** (sub-collection `entries`)
  where DR = money in, CR = money out, and each row stores the accumulated `balanceAfter`.
- **Flows:** the admin **funds/withdraws** member wallets by transferring to/from a cash
  wallet (paired CR+DR ledger postings). A **member spends only from their own wallet**, hard-
  limited by its balance. A member's **monthly cap** is a *soft red flag* (over-cap expenses
  still post, marked red), not a block.
- **Roles in the UI:** a member sees only their own wallet, own chat entries, and own reports;
  the admin sees everyone.
- **Teams = workers, not family members.** A team is a group of **workers** for the family
  (maids, drivers…). A worker is a member doc **tagged with `teamId`** (and a wallet with the
  same `teamId`) — kept out of the family proper. Only the **admin** sees/manages teams (under
  الفرق): adds workers, funds/withdraws their wallets. A team has **no pot**; its number is the
  **rollup = sum of its workers' wallet balances**, and a worker's expense comes from their
  **own wallet**. A worker who logs in (via a team invite) lands in a **team-only view** of
  their own data and never sees the family. Every family view (members list, settings member
  wallets, analytics) **excludes workers** (`isFamilyMemberWallet` / `getFamilyMembersSync`).

## Data model (Firestore)

- `families/{groupId}` with subcollections: `members`, `messages`, `transactions`, `budgets`,
  `categories`, `learnedKeywords`, `wallets` (+ each wallet's `entries` ledger), `teams`,
  `notifications`.
- A wallet doc carries `ownerType` (`admin`|`member`), `ownerId`, `description`, `balance`,
  `updatedBy*`, `archived`. A transaction/message carries `overCap`; a message also carries
  `targetUserId` (admin→member direct messages); a notification carries `targetUserIds`.
- Top-level: `inviteCodes`, `familyNames` (family-name uniqueness lock), `diagnostics`.
- Collection-group queries (`members.phone`, `members.authUid`, `teams.memberIds`) back join
  and session-restore; their indexes live in `firestore.indexes.json`, access rules in
  `firestore.rules`.

## Reports (`analytics_screen`)

Period picker (today/week/month/3mo/all/custom) + a member filter (admin). Collapsible
sections: summary (expenses/balance/income/net), by-category (pie+list), by-member balances,
by-wallet, over-time trend, budgets-vs-actual — all scoped to the viewer (members see only
their own).

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
