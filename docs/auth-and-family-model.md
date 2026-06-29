# Authentication & Family Model

## Login uses real credentials (Firebase Auth, no SMS)

- **Google sign-in** or **email + password**.
- Web uses `signInWithPopup`; Android/iOS use the native `google_sign_in` account picker (not
  the browser-redirect provider flow).

## The phone number is a family identifier, not a login

The family admin assigns a phone to each member; on join the member types their phone and it
must match the one carried by the invite. No SMS/OTP is involved.

## Roles: admin vs member

- The **admin** (family leader) funds members, manages cash wallets, sees the whole family,
  and reaches Settings/Teams. Tapping a member opens the **per-member screen** (their wallet +
  fund/withdraw + a direct message box).
- A **member** logs spending from their own wallet and sees **only their own** wallet, chat
  entries, reports, and notifications. They have no Teams, can't open family Settings (the chat
  header opens their own wallet instead), and can't add wallets or fund anyone.

## Family lifecycle

- A family **name is globally unique**, enforced by a lock document `familyNames/{nameKey}`.
- **Create family** (`DatabaseService.createFamily`): unique name + phone; the creator becomes
  admin.
- **Invite codes are one-time and consumed.** `createInvite(groupId, teamId?)` mints a fresh
  single-use code into `inviteCodes/{code}` each time the admin shares a link
  (`install.html?invite=CODE`). `joinByCode` reads the code from the link, rejects
  missing/already-used codes, **self-joins** (creates/binds the member, provisions their wallet,
  adds them to the team for a team code), then marks the code `used`. No pre-registration is
  required; the joiner just enters their name (phone optional — a matching phone reuses an
  admin-pre-registered slot and its permissions).
- **Returning login:** after sign-in the auth screen lists the account's existing memberships
  and shows an **enter** button per family (with the role) — returning members/admins log in,
  they do not re-join. Re-join only appears for a brand-new member with no membership.
- **Session restore** keys off the login UID via the `members.authUid` collection-group index.
  `restoreSession` calls `waitForAuthReady()` first, because Firebase restores `currentUser`
  asynchronously on cold start.

## Known constraints

- Web Google requires the Google Cloud OAuth web client to authorize origin
  `https://budget-home-bayoumi.web.app` and redirect URI `…/__/auth/handler` (console-only;
  no CLI). Without it: `redirect_uri_mismatch`.
- Web `authDomain` is set to `budget-home-bayoumi.web.app` (same-origin) to avoid
  storage-partitioning ("missing initial state"). Re-running `flutterfire configure` reverts it
  to `firebaseapp.com` — re-apply afterward.
- **Mobile-browser Google sign-in is unreliable** (popup/redirect storage partitioning). On
  phones use the **APK** (native Google) or **email/password** on mobile web.

Console prerequisites in place: Google and Email/Password providers enabled; the Android SHA-1
is registered.

## See also

- [Overview](overview.md)
- [Architecture](architecture.md)
- [Development & Deployment](dev-and-deploy.md)
