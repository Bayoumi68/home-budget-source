# Architecture

A client-side Flutter app over Firebase. Code in `lib/` is organized in three layers.

## Layers

- **screens/** — UI. Key screens: splash, auth, chat (the main logging surface; long-press a
  message to reply WhatsApp-style or copy it), analytics (reports), members, member_detail
  (admin's per-member view: wallet, fund/withdraw, and the conversation with that member),
  teams, group_settings (+ learned-keywords review), notifications.
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
their own). Each **by-wallet row folds/expands** to that wallet's full DR/CR ledger movement.

## Offline Arabic parser (`ai_service.dart`)

The "AI" is **not an API or ML model** — a deterministic, fully offline rule/keyword parser,
and **intent-first**: the **verb decides the action**, not the presence of a number.

- **Money commands** (`parseMoneyCommand`) are matched first, by verb — so a number alone is
  never assumed to be an expense:
  - **add** (إضافة/أضف), **withdraw** (اسحب/سحب), **transfer** (حول/تحويل/نقل),
    **raise/lower a spending limit** (رفع حد/تزويد | خفض/تخفيض/تنزيل حد).
  - Direction words **من / إلى / لـ** resolve source/target to a **wallet or a person**
    (member/worker) by name; anything unspecified prompts a picker. All are admin-only,
    **confirm before executing**, and **notify both parties**.
- **Expense / income** is the fallback only when no money verb is present: extracts the amount
  (currency-anchored, skips quantities/units), detects the category (keyword + Levenshtein
  typo tolerance), classifies income vs expense.
- **Wallet questions** — balance (رصيد المحفظة) and statement (حركة/كشف المحفظة).

**Learning loop:** correcting a transaction's category (long-press → change type) stores that
message's words → category in `learnedKeywords`; later parses consult learned keywords first.
An admin reviews/deletes wrong ones in **Settings → الكلمات المتعلَّمة**. Only *categories* are
learned — the action verbs above are fixed in code. The app adapts per family, no server/model.

## Categories

19 expense + 5 income categories with emoji icons, defined in `lib/config/constants.dart`.

## See also

- [Overview](overview.md)
- [Authentication & Family Model](auth-and-family-model.md)
- [Development & Deployment](dev-and-deploy.md)
