---
type: report
title: Manual Walkthrough — Android and macOS
created: 2026-08-28
tags:
  - ui
  - ux
  - audit
  - manual
related:
  - '[[ui-audit]]'
  - '[[route-inventory]]'
  - '[[a11y-audit]]'
---

# Manual Walkthrough — Android and macOS

Every other phase in this playbook asserts something a test can express. This
one looked at the app. Thirty-one surfaces on an Android emulator and
twenty-nine in a macOS window, photographed under eight sets of viewing
conditions, and then *read* — for gaps that do not match their neighbours,
labels that truncate, controls that are drawn but cannot be pressed, and the
kind of failure that only appears when somebody turns their font size up.

[`ui-audit.md`](ui-audit.md) is the machine's list and this is the human one.
Where they overlap, this file points there rather than repeating the entry.

## Method

The screens were captured by the Phase 04 route walk
([`route_walk_test.dart`](../../apps/weft/integration_test/route_walk_test.dart))
and read by hand afterwards. That is a deliberate split: driving thirty-one
surfaces by thumb produces the same pixels as driving them from a finder, and
the part of this phase that cannot be automated is the *looking*, not the
tapping. What the walk could not do before this phase, it can now — see
[What the walk gained](#what-the-walk-gained).

### The eight passes

Everything below is a real window on a real device or a real Mac, not a widget
test's surface.

| Pass | Platform | Window | Conditions |
|---|---|---|---|
| `phone` | Android emulator, API 36 | 412 × 915 | light, English, 1.0× |
| `phone-dark` | Android | 412 × 915 | dark |
| `phone-xl` | Android | 412 × 915 | 2.0× text |
| `phone-rtl` | Android | 412 × 915 | `ar`, right-to-left |
| `default` | macOS | 1400 × 900 | the Phase 04 baseline |
| `desk-narrow` | macOS | 720 × 640 | the **minimum window macOS allows** |
| `desk-wide` | macOS | 1800 × 1150 | a full-screen-ish window |
| `desk-dark` | macOS | 1400 × 900 | dark |

`desk-narrow` is 720 wide because that is exactly
`macos/Runner/MainFlutterWindow.swift:71` — `minSize = NSSize(width: 720, …)`.
It is not a hypothetical; it is the smallest window a person can drag the app
to, and it is where the worst macOS finding was.

Screenshots: `.maestro/playbooks/2026-08-28-Localization-UI-Audit-Features/Working/manual-walk/`
— `android/`, `macos/`, and the after-shots in `android-after/` and
`macos-after/`.

## What the walk gained

Three changes to the harness, all of which are findings in their own right
because each was hiding something.

**It could only see one set of conditions.** The walk pinned 1400 × 900 in
`boot()` and had done since Phase 04, so the "Android" run was the touch shell
at *tablet* width — a real layout, but not the phone, and not dark, large text
or right-to-left. `WEFT_WALK_PASSES` now names the conditions and the default is
byte-for-byte the old single pass, so CI is unchanged. Every app finding in the
table below came from a pass that did not previously exist.

**It threw its own photographs away on Android.** Both directories the walk can
write to on a device are inside the app, and `flutter test` uninstalls the app
when the run ends — so an Android walk photographed thirty-one screens, reported
a clean pass, and left nothing behind. It now prefers the app's external
directory (`getExternalStorageDirectory`), says out loud when a path is refused
instead of falling back silently, and `WEFT_WALK_HOLD` parks the run in
`tearDownAll` long enough for an `adb pull`.

**Its reset left the inbox scrolled.** `_reset` popped the navigator and
invalidated the providers but never restored the scroll offset, and the touch
shell's header *scrolls away* — so a part-scrolled inbox is an inbox with no
overflow menu on it. At the default pass the rows are short enough that this
never bit. At `phone-xl` it failed sixteen consecutive steps with `Bad state: No
element`, which read exactly like "large text makes Settings unreachable". It
was not: a probe at 1.0×, 1.3× and 2.0× found all six menu entries present and
on screen at every scale. **A harness bug that impersonates an app bug is worse
than either**, and two of the three overflows below were
on surfaces it hid.

## Per-surface notes

Grouped as the [route inventory](route-inventory.md) groups them. "Clean" is
never shorthand for "did not look" — it names what was checked.

### The inbox — `01`, `02`, `03`, `06`–`11`

The conversation list, its filters, search, the new-chat paths, the appearance
sheet and message requests.

- **Android, 1.0×.** The rail is 72pt of a 412pt phone, which is a lot but is
  the rail's job and reads correctly. Rows are on a clean grid: avatar, title
  and timestamp share a top alignment, badges right-align to a common edge, and
  the two-digit badge grows into a pill rather than shifting the column.
  Sentence case is consistent across chips, headers and menu entries.
- **The compose button sits on the last conversation.** The list reserved 24pt
  under itself and the button occupies 72. Finding **MW-01**.
- **Android, 2.0×.** The title truncates to "Convers…" and the filter chips
  clip "People" at the right edge — both acceptable, both a scrolling row and an
  ellipsis doing their job. The message-request card does not: finding
  **MW-02**.
- **Android, RTL.** Clean, and checked specifically: the rail moves to the
  starting edge, the badge column mirrors, the chevron on the message-requests
  row reverses, and the search field's icon and hint swap sides.
- **macOS.** The source list, the list and the thread. At `desk-narrow` the
  thread is 192pt: finding **MW-05**.

### The conversation — `20`–`24`, `89`–`91`

- **Android, 1.0×.** Bubbles group correctly, the network label appears on the
  first of a run and not the rest, the agenda chip aligns to the bubble's
  leading edge, and the receipt ticks sit with the timestamp rather than under
  it.
- **Android, RTL.** The strongest surface of the whole walk. The thread mirrors,
  the accent rail swaps to the trailing edge on both incoming and outgoing
  bubbles, the timestamp and receipt swap as a unit, the composer's four
  controls reverse as a group, and the agenda chip renders an Arabic date beside
  its English label — which is the documented half-state
  (`localisation.dart:44`), not a defect.
- **Android, 2.0×.** The message actions sheet clips its reaction row: finding
  **MW-03**.
- **The header subtitle truncates early** — "Merged · WhatsApp, …" at phone
  width, with three action icons beside it. Recorded as **MW-06** and deferred.

### Merged chats — `24`

- **Android, 2.0×.** Two findings on one screen: the suggestion card's action
  row clips *Merge* (**MW-02**, same shape as the request card) and the extended
  FAB covers the *Unmerge* buttons of the last merged contact (**MW-01**).

### Settings — `30`–`41`

Twelve screens, walked top to bottom on both platforms and at every pass.

Clean, and this is the group where "clean" took the most looking: the settings
rows share one leading-icon edge, section headers use one weight and one size,
subtitles wrap rather than truncate, and every screen's outer margin is the same
token as its neighbours'. At 2.0× every row grows and none of them clips. The
twelve macOS findings the scan reports here are the icon-only toolbar controls
already tracked as **UI-04a**–**UI-04d** and **UI-06** in
[`ui-audit.md`](ui-audit.md#medium--six-controls-smaller-than-the-floor-all-macos-all-icon-only)
— not repeated here.

### The auth gate

Not walked. The route inventory marks these as reached by overriding the session
provider rather than by tapping, and the walk covers them that way; there is no
cold-install path through them on an emulator seeded with demo fixtures. Called
out rather than left implied.

## Findings

| ID | Surface | Platform | Severity | `file:line` | Finding | Status |
|---|---|---|---|---|---|---|
| MW-01 | inbox, merged chats, bridges, auto-reply | Android (both layouts) | **bad** | `inbox_shell.dart:351`, `merge_screen.dart:139`, `bridges_screen.dart:415`, `auto_reply_screen.dart:46` | A floating compose/add button covers the last row of the list under it, with nowhere left to scroll. On merged chats that row carries an *Unmerge* button, so the control could not be pressed at all. Four screens with a FAB, four different bottom paddings — 12, 16, 24 and a hand-written `xxl * 2`. | **fixed** |
| MW-02 | message requests, merged chats | Android, 2.0× | **blocker** | `requests_screen.dart:271`, `merge_screen.dart:294` | An action row of buttons sized by their labels is a `Row`, which at 2.0× overflows by 60 and 90 points and clips its **last** child — *Accept* on a request, *Merge* on a suggestion. Block and Decline stayed reachable; Accept did not. | **fixed** |
| MW-03 | message actions sheet | Android, 2.0× | **blocker** | `message_actions_sheet.dart:170` | Six quick-reaction emoji plus the picker button are a `Row`; emoji are text and scale, so at 2.0× the row overflows by 116 points and clips the picker button — the way to every emoji that is not one of the six. | **fixed** |
| MW-04 | scale | both | polish | `tokens.dart:56` | `WeftSpace` had no step for "clear a floating button", so the one screen that got it right wrote `WeftSpace.xxl * 2` by hand and the other three guessed. | **fixed** |
| MW-05 | Mac window | macOS, 720pt | **bad** | `mac_shell.dart:53`, `surface.dart:145` | The sidebar and list are fixed widths and the thread is `Expanded`, so the thread pays for a narrow window and nothing stopped it paying everything: at the 720pt minimum the thread got 192pt — less than the conversation *list* beside it may shrink to. | **fixed** |
| MW-06 | conversation header | Android, phone | polish | `chat_view.dart` | The merged-chat subtitle truncates to "Merged · WhatsApp, …" at phone width, so the networks a merged thread spans cannot be read from the header. | **deferred** |
| MW-07 | route walk harness | both | **bad** | `route_walk_test.dart` | The walk could photograph only one set of conditions, discarded its Android screenshots at teardown, and left the inbox scrolled between steps — which hid sixteen surfaces at 2.0× behind a failure that looked like an app bug. | **fixed** |
| MW-08 | merged chats | Android, 1.0× | **bad** | `merge_screen.dart:294` | **Introduced by MW-02's fix, found by the re-walk.** A `Row` fills its width; a `Wrap` sizes to its widest run — so `WrapAlignment.end` had no free space to distribute and *Merge* moved 85 points in from the trailing margin it used to sit against. No overflow, no failing test, just wrong. | **fixed** |
| MW-09 | Mac list toolbar | macOS, list at `listMinWidth` | polish | `mac_shell.dart:433`, `mac_toolbar.dart:90` | The list pane's toolbar cannot hold its search field once the field is focused and grows from 120 to 180: at a 240pt list the row is 36 points over. Reachable by dragging the splitter to its minimum. Surfaced when MW-05's first target drove the list there without a drag. | **deferred** |

Severity: **blocker** = a control cannot be reached; **bad** = a control is
covered or a pane is unusable; **polish** = it reads wrong.

## The spacing table

Measured from the source rather than from the screenshots, and compared against
`WeftSpace` and against the same visual relationship elsewhere — which is the
comparison the [automated scan cannot make](ui-audit.md#what-the-spacing-scan-cannot-see).
Every value below was already *on* the token scale. That is the point: an
on-token value can still be the wrong on-token value, and four screens using
four different correct-looking tokens for one relationship is what that looks
like.

| `file:line` | Relationship | Was | Same relationship elsewhere | Now |
|---|---|---|---|---|
| `inbox_shell.dart:351` | conversation list ↔ compose button | `WeftSpace.xl` (24) | `auto_reply_screen.dart:46` used `WeftSpace.xxl * 2` (64) | `WeftSpace.fabClearance` (80) |
| `merge_screen.dart:139` | list ↔ extended FAB | `WeftSpace.lg` (16), all four sides | as above | `fabClearance` on the bottom, `lg` on the other three |
| `bridges_screen.dart:415` | list ↔ extended FAB | `WeftSpace.md` (12), all four sides | as above | `fabClearance` on the bottom, `md` on the other three |
| `auto_reply_screen.dart:46` | list ↔ extended FAB | `WeftSpace.xxl * 2` (64) — arithmetic, not a token | the only screen that reserved anything near enough | `fabClearance` (80) |
| `requests_screen.dart:287` | between the three verdict buttons | 0, 0, then `WeftSpace.xs` (4) before *Accept* only | `merge_screen.dart` used a uniform `WeftSpace.sm` | uniform `Wrap(spacing: WeftSpace.xs)` |
| `merge_screen.dart:294` | between the two suggestion buttons | `SizedBox(width: WeftSpace.sm)` | — | `Wrap(spacing: WeftSpace.sm)`, unchanged at 1.0× |

**Why 80.** A `FloatingActionButton` is 56 tall and `Scaffold` floats it
`WeftSpace.lg` above the bottom edge, so a list needs 72 before its last row
clears the button and `WeftSpace.sm` more before the two touch. 80 is on the 4pt
grid and is arithmetic rather than taste, which is why it is documented in
`tokens.dart` as a *clearance* and explicitly not as a rhythm step.

**Why `detailMinWidth` is 300 and not 320.** The first attempt said 320 and the
test caught it: 720 − `sidebarMinWidth` (180) − `listMinWidth` (240) = 300 is
the most the thread can be *promised* at the minimum window. A larger constant
would have been a guarantee the shell could not keep.

## Triage

**Fix now** — MW-01, MW-02, MW-03, MW-04, MW-05, MW-07. All six are contained:
four are a token or a padding, one is `Row` → `Wrap`, one is a pure function
over three widths.

**Fix now, needed a decision** — two.

- *MW-02, the request card's button row.* A `Wrap` right-aligns everything by
  default, which would have moved *Read* away from the leading edge where the
  `Spacer` had put it. Decided: keep the two groups as two groups — an outer
  `Wrap` with `spaceBetween` holding *Read* and an inner `Wrap` of the three
  verdicts. At 1.0× the layout is identical to what shipped; at 2.0× the
  verdicts drop to their own line instead of off the card.
- *MW-05, the narrow Mac window.* The alternative was raising `minSize` in
  `MainFlutterWindow.swift` so three panes always fit, which would have taken
  the app's minimum window from 720 to about 900 — a product change to fix a
  layout bug, and one that hurts small screens. Decided: squeeze the panes
  instead, sidebar first and list second, each to its own floor, leaving the
  dragged widths untouched so widening the window restores them.

**Deferred** — two.

- *MW-06, the truncated merged-chat subtitle.* Real, and not a spacing fix: the
  header would need either a second line at phone width, a tap that opens the
  network list, or the icons moved into an overflow. Each is a design decision
  about the chat header rather than a token swap, and the information is one tap
  away in the contact sheet today. Filed here rather than dropped.
- *MW-09, the Mac list toolbar at its minimum width.* This one was attempted and
  backed out, which is worth recording in full. The fix looked like two lines —
  make the toolbar's actions row `Flexible` so it is measured against a bound
  rather than against infinity, and `Flexible` the search field inside it — and
  it did remove the overflow. It also moved the *conversation* toolbar's three
  buttons 520 points to the left, because `Flexible` defaults to `flex: 1` and
  the actions then split the row's free space with the `Expanded` title instead
  of sitting after it. Four Mac goldens caught it, which is the system working.
  A correct fix needs the actions measured against a bound *without* taking a
  share of the free space, and `Flexible(flex: 0)` is not that — `RenderFlex`
  treats zero flex as inflexible and hands it infinity again. That is a change
  to `MacToolbar`'s layout contract and to every screen using it, which is more
  than this phase should do on the way past.

  So MW-05's target was set to 240 instead of 300, which takes the thread from
  192 to 240 using the sidebar's slack alone and never drives the list to the
  width that breaks. MW-09 is left exactly as reachable as it was before this
  phase — by dragging the splitter — and is now written down, with the
  reproduction and the failed approach, instead of being discovered again.

Nothing else was dropped. The twelve macOS tap-target findings the scan reports
on every pass are not new and are tracked in [`ui-audit.md`](ui-audit.md).

## The fixes, and the re-walk

Each fix has a test that fails without it. That was checked by reverting each
change in turn and confirming the red — a test that passes both ways is not a
regression test, and the first version of the merge-screen case was exactly
that: at 1.0× the list does not scroll, so the last row cleared the button by
hundreds of points with no padding at all. It now runs at 2.0×, and
`scrollToEnd` asserts there was something to scroll before it asserts anything
about where the row ended up.

| Finding | Fix | Test |
|---|---|---|
| MW-01 | `WeftSpace.fabClearance` as the bottom inset on all four lists. Applied to **both** inbox layouts — two panes positions its compose button into the pane's own `Stack` (`inbox_shell.dart:234`) rather than the `Scaffold` slot, which the first attempt missed. | `test/fab_and_pane_clearance_test.dart` |
| MW-02 | `Row` → `Wrap` on both cards, groups preserved. | `test/a11y/large_text_layout_test.dart` |
| MW-03 | `Row` → `Wrap` with `spaceBetween`; identical run at 1.0×, a second run at 2.0×. | `test/a11y/large_text_layout_test.dart` |
| MW-04 | `WeftSpace.fabClearance = 80`, documented as a clearance. | used by the above |
| MW-05 | `macPaneWidths` — a pure function, plus `MacMetrics.detailMinWidth = 240`. The sidebar gives up its slack and the list is left alone; see MW-09 for why the target is 240 and not 300. | `test/fab_and_pane_clearance_test.dart` |
| MW-07 | `WEFT_WALK_PASSES`, `WEFT_WALK_HOLD`, an external-storage shot directory, a loud failure when a path is refused, and a scroll reset in `_reset`. | the re-walk itself |
| MW-08 | `SizedBox(width: double.infinity)` around the merge card's `Wrap`. Deliberately *not* added to the request card, whose `Column` is already `CrossAxisAlignment.stretch` — the two cards look identical and only one needs it, which is why both now say so in a comment. | `test/a11y/large_text_layout_test.dart`, the two 1.0× cases |

**Goldens: none changed, and none were updated.** Checked rather than assumed —
the full suite passes untouched. The bottom-padding changes are invisible from
the top of a list, and the `Wrap`s lay out identically to the `Row`s they
replaced at 1.0×, which is the scale every golden pins. Forcing an update here
would have written noise into forty baseline images.

**Re-walk.** Both platforms, same passes, after the fixes — and it earned its
keep twice: MW-08 and MW-09 are both things the re-walk found and review had
not. Reading the after-shots beside the originals is what turned "the overflow
is gone" into "the overflow is gone and the button is in the wrong place".
After-shots are in `manual-walk/android-after/` and `manual-walk/macos-after/`.

## Verification

Run at the end of the phase, over the whole workspace.

| Check | Result |
|---|---|
| `dart analyze` (workspace) | **No issues found** |
| `flutter test` (`apps/weft`, incl. every golden) | **1558 passing**, 0 failing, 1 skipped |
| package suites (17 packages, `dart test`; `flutter test` for `weft_design`, `weft_matrix`, `weft_store`) | all passing |
| `tooling/scripts/l10n_lint.dart` | 1177 keys × 5 locales — clean |
| `tooling/scripts/l10n_audit.dart` | 194 files; 3 hardcoded literals and 17 deliberate exclusions, unchanged by this phase |
| route walk — Android `phone` | **0 findings**, 31 steps, 1 skipped |
| route walk — Android `phone-xl` | **0 findings**, 31 steps, 1 skipped (was 3 overflows and 16 unreachable) |
| route walk — macOS `default`, `desk-narrow`, `desk-wide`, `desk-dark` | 12 findings each, all pre-existing tap targets; **no overflow at any width** |

Two things this table is not claiming. The three hardcoded literals in the l10n
audit are Phase 02's tracked remainder, not something this phase introduced or
resolved. And the 12 macOS findings per pass are the same 12 in every pass and
the same 12 as before the phase — the icon-only toolbar controls in
[`ui-audit.md`](ui-audit.md), which this walkthrough did not set out to fix.

The one skipped walk step is `05-status-viewer`, whose precondition — somebody
having posted a status — the demo fixtures do not carry. It is reported by name
on every run rather than passing quietly.

## Keeping this true

The passes are the durable part. `WEFT_WALK_PASSES=phone,phone-dark,phone-xl,phone-rtl`
on a device and `default,desk-narrow,desk-wide,desk-dark` on a Mac is the walk
this phase did; re-running it is how a future phase asks the same questions
without a person having to remember what they were. The two new test files are
the parts that fail on their own — a `Row` that stops fitting and a pane that
starves the thread are both now red in the ordinary suite rather than in a walk
somebody has to think to run.
