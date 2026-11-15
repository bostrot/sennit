---
type: decision
title: 'ADR-004: open source with a paid Pro tier'
created: 2026-10-22
status: proposed
tags:
  - licensing
  - billing
  - open-source
related:
  - '[[ADR-002-ios-signing-handoff]]'
---

# ADR-004: open source with a paid Pro tier

**Status:** proposed — built, not switched on · **Date:** 2026-10-22, revised 2026-11-15

## Context

Braid is to be published as open source and still pay for itself. The model
to follow is Readest's: the whole app is public, and the store builds sell the
parts that cost the most to build and keep working — there, cloud storage
tiers or a one-time "all features" purchase; here, the AI features and the
integrations, as a one-time purchase: through Google Play, through the App
Store, and — for the builds on the release page — through Stripe. A
subscription comes later, with a hosted AI service to justify it.

The repository is already AGPL-3.0, and every one of its commits so far has the
same author. Both facts matter below.

## Decision

### Three editions, one codebase

`BraidEdition` in `apps/weft/lib/services/billing/entitlements.dart`, chosen
with `--dart-define=BRAID_EDITION=…`:

| Edition | Who gets it | How Pro is bought |
|---|---|---|
| `community` (the default) | anyone who builds from source, CI, every test | it is not: everything is unlocked |
| `store` | Google Play and the App Store | in-app purchase |
| `direct` | the release page: APK, macOS, Windows, Linux | a licence key bought on the web |

The default is community on purpose. A source checkout, a contributor's debug
build, CI and every test get the whole app with nothing to configure, and
only the release pipelines opt in to charging. Hiding the paid code would buy
nothing: under the AGPL anyone may build it with the gate removed. People pay
for the convenience of the published build and to keep the project going, as
they do for Readest.

The store edition charges only where a store can take the payment, which is
Android and iOS; anywhere else it unlocks everything. The direct edition
charges on every platform. The two never mix: Apple does not allow an app to
unlock features with a licence key, and Play does not allow an app it
distributes to send people to another checkout, so a store build has no key
field and a direct build has no store.

### What Pro unlocks

`ProFeature` names each gate:

| Feature | Gate |
|---|---|
| Auto-replies, notification reply suggestions, the to-do assistant | `autoReplyEndpointProvider`, `suggestReplies` |
| Semantic search, on-device or through an endpoint | `embeddingProviderProvider` |
| Voice-note transcription, on-device or through an endpoint | `transcriptionProviderProvider` |
| The MCP server | `McpService.start` |
| Home Assistant, paperless-ngx, the shared calendar | `homeAssistantProvider`, `paperlessProvider`, `icsCalendarProvider` |

Everything else stays free: every network and bridge, merged chats, calls, SMS,
search by keyword, backups, statuses, widgets, appointment detection, and the
to-do list itself.

The gates sit in the providers, not only on the settings rows. A user who set
up an endpoint before Pro existed must not keep using it through the back
door. In the settings list, the AI, Integrations and MCP rows carry a "Pro"
badge and open the Pro screen until Pro is bought.

### Products

| Where | Product | Price |
|---|---|---|
| Play | `braid_pro_lifetime`, one-time product | EUR 14.99, converted per region |
| App Store | `braid_pro_lifetime`, non-consumable | EUR 14.99 base, Germany |
| Stripe | "Braid Pro", one-time price, sold through a Payment Link with metadata `app=braid` | EUR 14.99 |

Both stores use the same id, so one table serves both, and the Pro screen
shows whatever price the store returns, already in the user's currency.
`tooling/store/iap_products.py` creates the store products; the *Store
products* workflow runs it with the deploy credentials.

`braid_pro_monthly` is in the code and in no console. The Pro screen lists
only what the store returns, so it stays invisible until it is created. It is
meant for the hosted AI endpoint, if one comes: a product that unlocks its
own set of `ProFeature`s, with the existing gates left as they are.

### Proof of purchase

`ProController` (`apps/weft/lib/app/billing_providers.dart`) listens to the
store's purchase stream on every launch and asks for a restore. Each purchase
it sees is acknowledged, even one it does not recognise, because Play refunds
an unacknowledged purchase after three days. The last confirmed purchase is
saved in settings, so the app works offline.

A subscription counts for seven days after the store last confirmed it. The
plugin reports no renewal date without server-side checks, and the restore on
launch re-confirms a live subscription. A cancelled one stops working at most
a week after it lapses.

`purchaseVerifierProvider` trusts the store. For a one-time purchase that is
enough. **Before a subscription is sold on iOS, it must check receipts on a
server:** a StoreKit restore can replay transactions from a subscription that
has since lapsed.

### Licence keys

A direct build's Pro screen has a button to the checkout page and a field for
the key. The key is checked once with the licence service
(`tooling/licensing/`, an n8n workflow fed by a Stripe webhook) and then
saved; the app asks again about once a month. Only a definite "not valid"
takes Pro away, so a server that is down, or a year offline, costs the user
nothing. The request carries the key and nothing else — no device id, no
account — because a licence covers every device its owner uses and there is
nothing to count.

## Before the repository goes public

Checked on 2026-11-15:

- [x] The licence is AGPL-3.0 (`LICENSE`), and `CODE_OF_CONDUCT.md`,
  `CONTRIBUTING.md`, `SECURITY.md` and `PRIVACY.md` are in place.
- [x] No credentials are in the tree or in its history. `gitleaks` over every
  commit finds one thing, a made-up key in a test fixture. Also searched by
  hand: keystores, `key.properties`, `google-services.json`,
  `GoogleService-Info.plist`, `.p8`, `.p12`, provisioning profiles, `.env`
  files, private-key blocks and tokens. CI secrets stay in GitHub.
- [x] All commits have one author. The copyright holder may therefore ship
  the same code through the App Store, whose terms the AGPL does not allow a
  third party to accept.
- [x] **Contributions are licensed for that too.** `CLA.md` is agreed to by
  opening a pull request, and the pull request template says so.
- [x] **The name is not part of the licence.** `TRADEMARKS.md` asks forks to
  rename.
- [x] **A fork's pull request cannot run on our machines.** CI runs on
  self-hosted runners; `ci.yaml` skips every self-hosted job for a pull
  request from a fork and gives it a GitHub-hosted job instead.
- [x] **The release-page builds are the direct edition**, once there is a
  checkout to send people to.
- [ ] **Decide what happens to existing testers.** The first charging build
  locks AI features they use today. One option is to give each a licence key
  or a store promo code.

Firebase is not configured in the repository (`Firebase.initializeApp()` reads
platform files that are not checked in), so a fork that wants push through
Google has to bring its own. UnifiedPush works without it.

## Switching it on

Nothing charges until two repository variables say so, so each step can be
done and checked on its own.

1. **Stripe.** Create the product "Braid Pro" with a one-time price, a
   Payment Link with metadata `app=braid`, and a webhook endpoint to
   `/webhook/braid/stripe-events`; `tooling/licensing/README.md` has the
   detail. Buy once with a 100 % coupon and check that the email arrives and
   the key activates. Then set the repository variable `BRAID_CHECKOUT_URL`
   to the Payment Link: the next release's APK and desktop builds are the
   direct edition.
2. **Play Console and App Store Connect.** Accept the paid-apps agreements,
   then run the *Store products* workflow, first without and then with
   "apply". In App Store Connect, add a review screenshot of the Pro screen
   and submit the product with the next version. Add licence testers in Play.
3. Set the repository variable `BRAID_STORE_EDITION` to `store`. The next
   internal-track and TestFlight builds charge; buy, restore and refund
   there before promoting anything to production.

## Later: the subscription

Create `braid_pro_monthly` in both consoles, add receipt verification behind
`purchaseVerifierProvider`, and decide which `ProFeature`s it unlocks.

## Consequences

- Every new AI or integration feature needs a `ProFeature` gate in its
  provider, or it ships free in the store build.
- Tests run as the community edition. A test about a gate overrides
  `braidEditionProvider`, as `test/braid_pro_test.dart` does.
- `in_app_purchase` is linked into every build, the community edition
  included. It does nothing until the store edition calls it.
- The licence service is one more thing to keep running. If it is down,
  nobody loses Pro, but nobody new can activate a key.
