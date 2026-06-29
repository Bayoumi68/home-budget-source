---
name: budget-home-overview
description: "What the Home_Budget project is — stack, purpose, key architecture"
metadata: 
  node_type: memory
  type: project
  originSessionId: 5e670845-0177-4933-8e31-683257188133
---

`E:\PycharmProjects\Home_Budget` is **Home Budget** (renamed from "Budget Home"), an Arabic-first, chat-driven **family budget** app. Stack: **Flutter (Dart) + Firebase** (Cloud Firestore + Firebase Auth). Cloned 2026-06-28 from github.com/Mokamal10/budget-home-source, then re-pointed to the user's **own** Firebase project `budget-home-bayoumi` and the user's **own** GitHub repos (see [[dev-environment]]).

The "AI" is **not an API** — it's a fully offline Arabic NLP parser in `lib/services/ai_service.dart` that turns chat text ("دفعت 250 سوبر ماركت") into transactions. It's rule/keyword-based (no model). As of this session it was hardened: currency-anchored amount extraction (skips quantities), score-based category matching, edit-distance typo tolerance, refund detection — plus an **offline learn-from-corrections loop**: long-press an expense → "تغيير النوع" saves the message's words → category in a `learnedKeywords` Firestore collection, which the parser then consults.

Firestore tree: `families/{groupId}` with subcollections members, messages, transactions, budgets, categories, learnedKeywords, wallets, teams, notifications; plus top-level `inviteCodes`, `familyNames` (name-uniqueness lock), `diagnostics`. Live web app: https://budget-home-bayoumi.web.app. See [[auth-verification-approach]].
