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
  (matched by **both `authUid` and email**, so every slot the account owns shows — e.g. admin +
  a child in the same family) with an **enter** button per slot (name + role). Returning
  members/admins log in, they do not re-join. Re-join only appears for a brand-new member.
- **Account recovery:** members are keyed by **`phone_<phone>`**, so reusing one phone for two
  people collapses them into one record (e.g. a worker created with the admin's phone overwrites
  the admin row). **"عائلتك بلا قائد؟ استعد حساب القائد"** on the login screen reconnects the row
  that `families.adminId` points at to the current login and strips any worker tag. The admin can
  also re-bind by phone. A person's **phone is editable only while their slot is still pending**
  (not yet joined); after they join it's fixed.
- **Session restore** keys off the login via the `members.authUid` **and** `members.email`
  collection-group indexes. `restoreSession` calls `waitForAuthReady()` first, because Firebase
  restores `currentUser` asynchronously on cold start, and remembers the exact member last
  chosen.

## Known constraints

- **Auth domain is the Firebase default `budget-home-bayoumi.firebaseapp.com`** (NOT a custom
  web.app domain). Google specially handles `firebaseapp.com` for sign-in across browsers; a
  custom `home-budgets.web.app` authDomain broke **Chrome-on-Android** sign-in. Re-running
  `flutterfire configure` resets authDomain — re-apply this value.
- The OAuth web client must list the app origins as **Authorized JavaScript origins** and the
  handler **redirect URI** `https://budget-home-bayoumi.firebaseapp.com/__/auth/handler`
  (console-only; no CLI). Missing the redirect URI → "access blocked / redirect_uri_mismatch".
- **Web Google sign-in fails inside Chrome on Android** — the Firebase popup/redirect handler
  needs storage that mobile Chrome partitions ("missing initial state"). Desktop Chrome and
  Samsung Browser work. A GIS/FedCM rewrite was attempted and **reverted** (it blanked the web
  app); don't re-attempt without a real device to test on. **On Android use the APK** (native
  Google sign-in works); on mobile web use Samsung Browser or email/password.

Console prerequisites in place: Google and Email/Password providers enabled; the **release**
APK's Android SHA-1/SHA-256 are registered (required after switching to release signing).

## See also

- [Overview](overview.md)
- [Architecture](architecture.md)
- [Development & Deployment](dev-and-deploy.md)
