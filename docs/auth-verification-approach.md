---
name: auth-verification-approach
description: "Home Budget login & family model — Google/email auth, phone as family identifier, Google-on-web caveats"
metadata: 
  node_type: memory
  type: project
  originSessionId: 5e670845-0177-4933-8e31-683257188133
---

**Final design (redesigned 2026-06-28; replaced the earlier phone-SMS/SIM idea, which was fully removed).**

**Login = real credentials: Google sign-in OR email+password** (Firebase Auth, free, no SMS).
- Web: `signInWithPopup`. Android/iOS: **native** `google_sign_in` package (account picker) — *not* `signInWithProvider` (that opened a browser).
- The **phone number is NOT a login** — it's a family identifier the admin assigns; on join the member types their phone and it must *match* the invite's phone (no SMS).

**Family model:**
- Family **name is globally unique** (lock doc `familyNames/{nameKey}`).
- **Create family** (`DatabaseService.createFamily`): unique name + phone → creator is admin.
- **Join** (`joinFamily`): invite link carries `{groupId, assigned phone}` (`install.html?join=1&groupId=…&phone=…`); member signs in with own creds, types phone → must match → joins. Distinct from the create link.
- **Session restore by login uid** (`getMembershipsByAuthUid`, collection-group `members.authUid` index). `restoreSession` calls `waitForAuthReady()` first — Firebase restores `currentUser` async on cold start, so checking too early bounced logged-in users to login.
- Auth screen: after sign-in → two buttons only (**إنشاء عائلة جديدة** reveals the form; **تسجيل الدخول** opens existing family). Logout lives in the chat app-bar, the avatar account sheet, and Settings.

**Google-on-web caveats (important, hit repeatedly):**
- Web `authDomain` is set to **`budget-home-bayoumi.web.app`** (same-origin, avoids "missing initial state" storage partitioning). NOTE: re-running `flutterfire configure` reverts it to `firebaseapp.com` — must re-apply.
- For web Google to work, the **Google Cloud OAuth web client must authorize** origin `https://budget-home-bayoumi.web.app` and redirect URI `https://budget-home-bayoumi.web.app/__/auth/handler` (console only — no CLI/API exists; this was the unavoidable manual step). Without it: `redirect_uri_mismatch`.
- **Mobile-browser Google is broken** (popup→redirect→storage partitioning) with no fix → on phones use the **APK** (native Google) or **email/password** on mobile web.

**Console prerequisites (done):** Google + Email/Password providers enabled; Android SHA-1 `5E:FE:4B:94:70:31:9C:B9:71:E8:86:42:12:A7:71:0C:73:34:DA:F6` added. See [[dev-environment]], [[budget-home-overview]].
