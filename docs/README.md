# Home Budget — Documentation

Home Budget is an Arabic-first, chat-driven family budgeting app built on Flutter + Firebase.
Members log spending in everyday Arabic and the app turns each message into a categorized
transaction, then rolls it up into shared budgets and analytics.

## Contents

- [Overview](overview.md) — what the app is, the stack, and how it works.
- [Architecture](architecture.md) — Flutter layers, the Firestore data model, and the offline
  Arabic parser.
- [Authentication & Family Model](auth-and-family-model.md) — login, family identity, create
  vs. join, session restore.
- [Development & Deployment](dev-and-deploy.md) — toolchain, Firebase project, repositories,
  and build/run/deploy steps.
- [Firebase Setup](firebase-setup.md) — point the app at **your own** Firebase project: every
  project-specific value to replace, plus step-by-step console + CLI wiring.
