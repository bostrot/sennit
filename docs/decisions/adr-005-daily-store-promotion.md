---
type: decision
title: 'ADR-005: daily promotion from the test tracks to the stores'
created: 2026-11-20
status: accepted
tags:
  - release
  - play
  - app-store
  - ci
related:
  - '[[ADR-002-ios-signing-handoff]]'
  - '[[ADR-004-sennit-pro]]'
---

# ADR-005: daily promotion from the test tracks to the stores

**Status:** accepted, built, switched off · **Date:** 2026-11-20

## Context

A version bump on `main` ships to testers on both stores within twenty
minutes: `deploy_internal.yml` puts the bundle on Play's internal track and
`deploy_testflight.yml` puts an archive on TestFlight, both numbered with
the commit count of `main`, both with the notes `release_notes.py` writes.
Five versions (1.0.12 to 1.0.16) went out that way on 2026-11-19. What the
public sees moved only by hand, and has not moved since 1.0.9.

What the stores held on 2026-11-20, read through their APIs by the first
dry run (the brief said nothing had reached either store; that was not so):

| | Testers | Public |
|---|---|---|
| Google Play | internal: 1.0.16 (366) | open testing (`beta`): 1.0.9 (288); production: empty |
| App Store | TestFlight: 1.0.16 (366), **internal-only** | 1.0.9 (288), Ready for Sale; one review submission, complete |

The goal: once a day at 03:00 Berlin time, whatever testers got that day goes
public, provided something new did reach them that day.

## Decision

### Where it goes

- **Google Play: the open testing track (`beta`).** Production stays a step
  someone takes in the Console for now. The track is one setting, the
  repository variable `PLAY_PROMOTION_TRACK` (`--play-track`), so pointing
  the same promotion at production later changes nothing else. The release on
  the target track gets the internal release's version codes and its "What's
  new", and replaces what is there at 100 %. `PLAY_PRODUCTION_ROLLOUT` set
  below 1 makes it a staged rollout instead, which keeps the previous
  completed release next to it, as Play requires. Not by default: with a new
  release every day a staged rollout is still rolling out when the next one
  replaces it. `changesNotSentForReview` is not sent unless
  `PLAY_CHANGES_NOT_SENT_FOR_REVIEW` is `true`. Play needs it only when the
  Console has changes waiting that must not go to review with the release.
  Managed publishing, when it is on, still holds the release until someone
  publishes it; the script does not turn it off.
- **App Store: App Review, released automatically once approved.** The
  script creates the App Store version for the TestFlight build's version, or
  reuses the one open version and renames it, attaches the build, sets
  `releaseType` to `AFTER_APPROVAL` and "What's New" (en-US, from
  `release_notes.py`; Apple has none on an app's first version, so the
  script leaves it out there). It answers export compliance and submits
  through `reviewSubmissions`: it creates the submission, adds the version as
  an item, and sets `submitted`. A submission left unsubmitted by an earlier
  run is reused.

### Which build, precisely

Per store, the **candidate** is the newest build on the test track:

- Play: the `completed` internal-track release with the highest version code.
- App Store: the TestFlight build with the highest build number that has
  finished processing (`VALID`), has not expired, and is not
  `INTERNAL_ONLY`. App Store Connect will not attach an internal-only build to
  a version.

It is promoted when all of these hold:

1. **It is new to the target.** Its build number is higher than every build
   the target has. For Play, that is every `completed`, `inProgress` or
   `halted` release on the target track. For the App Store, it is every
   version on sale, in review, or between the two. This rule makes the
   promotion idempotent: once a run has promoted a build, every later run
   sees it as already there.
2. **It reached testers within the window.** The default window is 26 hours:
   one night to the next, plus slack for GitHub's late starts. Rule 1 already
   stops a build from going twice, so the slack cannot cause that. For
   TestFlight, "reached" is the build's `uploadedDate`. Play does not report
   when a release reached a track. For Play it is when the successful
   `deploy_internal.yml` run on that commit finished.
3. **CI passed on its commit, and its deploy succeeded there.** The build
   number is `git rev-list --count` of `main`, so the commit is found again
   from the number, on the first-parent line of `origin/main`. The run then
   needs a successful `ci.yaml` run and a successful deploy run (Play:
   `deploy_internal.yml`, TestFlight: `deploy_testflight.yml`) with that
   `head_sha`. If CI on a release commit was cancelled because a newer push
   superseded it (1.0.15's was), that version does not go out until CI is
   re-run on it. A red or missing gate fails the run, so someone hears of it.
   A quiet night, with nothing new, ends green.

### One version in review at a time

Apple takes one App Store version at a time. When a version is waiting for
review, in review, or approved and not yet released, the newer build
**waits**. It does not replace the version under review. Cancelling a
submission puts it at the back of the queue and throws away the reviewer's
work. Review usually takes less than a day, so the next night normally finds
the queue empty and sends the newest build then. Builds in between are
skipped, which is fine for an app that ships daily. A version that was
**rejected** (`REJECTED`, `METADATA_REJECTED`, `INVALID_BINARY`) stops the
App Store line and fails the run. A person reads the rejection before
anything else is submitted.

One consequence of rules 1 and 2 together: a build that waited behind a
review and is then followed by a quiet day falls out of the window. It goes
out with the next release, or with a manual run with `max_age_hours=0`. That
is the price of "only what landed that day", and the window is a single
input to change if it proves too strict.

### Export compliance

Each build needs the answer `docs/RELEASING.md` gives: standard algorithms,
not distributed in France. App Store Connect records the answer a person gave
on build 366 as `usesNonExemptEncryption = false`, with no encryption
declaration (the app has none). The script copies the newest answer a person
gave, together with its declaration if there is one, onto the build it
submits. It refuses to copy an answer whose declaration says France or
proprietary cryptography. A person answers again only if that answer ever
has to change.

### When it runs

GitHub's cron is UTC, and 03:00 in Berlin is 02:00 UTC in winter and
01:00 UTC in summer. The workflow is scheduled at both, and the script reads
the slot that started it (`github.event.schedule`). It goes on only when that
slot, on that UTC day, is 03:00 in Berlin. The gate uses the slot, not the
clock: GitHub often starts scheduled runs late, and a 01:00 slot starting at
02:05 must not pass as the 02:00 one. A test checks that exactly one slot
passes on every day of 2026, including both days the clocks change. A
concurrency group keeps two runs from overlapping.

### Release notes

The script uses the same text the stores already show testers. On Play, the
internal release's own "What's new" is copied: the short Play text, in every
language it has. If it has none, `release_notes.py --play-dir` runs on the
build's commit.
On the App Store, `release_notes.py --store` runs on the build's commit, in
a temporary worktree.

### The switch, and dry runs

`STORE_PROMOTION_ENABLED` (a repository variable) is the master switch:

- Off (unset, or anything but `true`): the scheduled runs are skipped and make
  no API calls. A manual run can only be a dry run.
- On: the 03:00 run promotes. A manual run with `dry_run` off promotes at
  once. That is the way to catch up, with `max_age_hours=0`.
  `deploy_testflight.yml` stops marking uploads internal-only, because the
  App Store side needs eligible builds. The builds still reach only the
  internal tester group.

A dry run (`dry_run`, the default for a manual run) reads both stores and
prints the decision and every step it would take. Play checks the would-be
release itself: the script puts it into an edit, asks Play to validate the
edit, and deletes it uncommitted. With `audit` it also lists what each store
wants for a release, as far as the APIs show it.

### GitHub Actions, not an Orca automation

An Orca automation would run on a laptop that has to be awake, online and
signed in at 03:00. It would need the store keys on that laptop, and it
leaves no shared log. A scheduled workflow uses the repository's existing
secrets and a hosted runner, and its log sits next to the deploy runs it
depends on. It also runs in the same place as everything it gates on. GitHub
pauses schedules after 60 days without repository activity, which a project
that ships daily will not reach. **GitHub Actions.**

## Before the switch goes on

From the 2026-11-20 dry run ([run 44683109232][dry]). `[x]` was confirmed
through the API; `[ ]` is missing or could not be checked.

**Google Play, open testing:** nothing the API can see is missing.
Open testing already serves 1.0.9, so Play has accepted the app's
declarations once.

- [x] Details: default language, contact e-mail, website.
- [x] en-US listing: title, short and full description, icon, feature
  graphic, 4 phone, 2 seven-inch and 2 ten-inch screenshots.
- [x] Open testing in 177 countries plus rest of world; Sennit Pro is active.
- [x] Play validated an edit that puts 1.0.16 (366) on `beta`.
- [ ] Not readable through the API; confirm in the Console:
  - Policy → App content is still complete (privacy policy, app access with
    the review login, ads, content rating, target audience, data safety).
  - Open testing is open to anyone, not a tester list.
  - Managed publishing is off, or someone publishes each night's release.
  - Android Auto: 1.0.16's notes say it answers messages in the car. Opt in
    under Advanced settings → Form factors; the first release that includes
    it goes through Play's Android Auto review.
- [ ] For production later: production countries, and, if the developer
  account is a personal one created after November 2023, the 12-tester,
  14-day closed test that Play requires before production access.

**App Store:** the listing is complete; two things block.

- [x] Content rights, category (Social Networking), privacy policy URL,
  name and subtitle, price schedule.
- [x] Available in 173 territories; France and mainland China are not among
  them.
- [x] 1.0.9's listing, which the next version is copied from: description,
  keywords, support and marketing URL; screenshots for iPhone (4),
  iPad 13" (2) and Apple Watch (1).
- [x] Review contact, demo account (required, set) and review notes. Sennit
  Pro is approved.
- [ ] **TestFlight builds are internal-only**, so none can be submitted.
  Turning the switch on fixes this from the next upload. To submit 1.0.16
  sooner, run `deploy_testflight.yml` once with `app_store` ticked.
- [ ] **Age rating:** `datingAndRelationships` and `sharedLocation` are
  unanswered in the questionnaire (App Information → Age Rating). They are
  among Apple's newer questions; answer them before the first submission
  rather than find out from a refused one.
- [ ] Not readable through the API: App Privacy labels still match 1.0.16
  (Siri and CarPlay are new since 1.0.9). The demo account's homeserver is up,
  and the account holds conversations (`tooling/scripts/seed_review_account.py`).

## Consequences

- With the switch on, every release that reaches testers by 03:00 is public on
  Play open testing that night, and in App Review that night. Releasing to
  testers now means releasing to the public the next morning. A version that
  must not go out needs the switch off before 03:00.
- The live write paths have not run yet: Play's commit, and on the App Store
  creating the version, copying the compliance answer and submitting. They
  run first under supervision, when someone turns the switch on. The dry run
  covers every read and the decision, and Play's validation covers the edit.
- `tooling/store/test_promote.py` (run in CI's "Store tooling tests") pins the
  selection rules, the detection of builds already promoted, the review
  policy and the Berlin slot.

[dry]: https://github.com/bostrot/sennit/actions/runs/44683109232
