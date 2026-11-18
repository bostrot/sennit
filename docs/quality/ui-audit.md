---
type: report
title: UI and Spacing Audit
created: 2026-08-28
tags:
  - ui
  - ux
  - audit
related:
  - '[[route-inventory]]'
  - '[[a11y-audit]]'
---

# UI and Spacing Audit

What a machine found by opening every screen in Sennit, on both shells, and
measuring it. The machine is
[`apps/weft/integration_test/route_walk_test.dart`](../../apps/weft/integration_test/route_walk_test.dart);
the list of screens it walks is [`route-inventory.md`](route-inventory.md).
This file is the work list it produced and what was done about each entry.

The accessibility audit next door — [`a11y-audit.md`](a11y-audit.md) — asks a
different question and has already been answered. That one is about what a
screen reader hears and whether a colour clears AA; this one is about pixels a
sighted person is looking at: gaps that are not on the scale, controls too
small to hit, and anything that overflowed.

## Method

One run per target, both in demo mode, both at 1400×900 with English pinned:

| Target | Shell | Command |
|---|---|---|
| macOS 26.3, `-d macos` | Mac window | `flutter test integration_test/route_walk_test.dart -d macos --dart-define=WEFT_DEMO=true` |
| Android emulator, API 36.1 | touch | `flutter test integration_test/route_walk_test.dart -d emulator-5554 --dart-define=WEFT_DEMO=true` |

Four scanners run on every surface the walk reaches
(`apps/weft/test/support/ui_audit.dart`):

- **exceptions and overflow** — `FlutterError.onError` is intercepted for the
  duration of each step, so a `RenderFlex overflowed` is attributed to the
  screen that produced it instead of scrolling past in a log. Fatal.
- **tap targets** — the traversal `MinimumTapTargetGuideline` uses, returning
  the offenders rather than a pass/fail. 48 on touch (`kWeftMinTapTarget`,
  Android's guideline); **24** on the pointer surface, which is WCAG 2.5.8's
  minimum and deliberately *not* `kWeftMinPointerTarget` — see the open finding
  UI-07 below.
- **unnamed controls** — `unnamedControlsIn` in `test/support/semantics_probe.dart`,
  the complement of the set `controlNamesIn` returns.
- **off-scale spacing** — a widget-tree scan for childless `SizedBox` spacers
  inside a `Row`/`Column`, and for every resolved edge of a `Padding`,
  `Container` or `AnimatedContainer`, reported when the value is not a
  [`WeftSpace`] token.

### What the spacing scan cannot see

Stated because a scan that quietly skips things reads as a clean bill of
health.

- **Only widgets created in this repository**, via
  `debugIsWidgetLocalCreation`. With no pub roots configured that means *not
  `packages/flutter/`*, so a widget built by a pub dependency reads as local
  and there is no public API to tell which — a finding whose chain names no
  Sennit widget is one of those. UI-06 was.
- **Whole numbers only.** Every gap in this tree is a literal on the grid; a
  fractional inset is always derived — `WeftAvatar`'s ring is `size * 0.055`,
  a badge's border a proportion of its extent. Those are strokes wearing
  padding's clothes, they scale with what they surround, and reporting them
  buried the real findings forty to one.
- **Platform metrics are exempt**, and so is a metric plus one spacing step:
  `MacToolbar` writes its traffic-light clearance as `leadingInset +
  WeftSpace.md`, which the scanner sees as a bare 90.
- **Release builds see nothing.** Creation locations need
  `--track-widget-creation`. The walk logs "the spacing scan did not run"
  rather than reporting a clean screen it never looked at.

## Results

Both runs green. Re-run 2026-08-28 on macOS 26.3.1 (`-d macos`) and on the
API 36 emulator (`-d emulator-5554`), after the harness fix in UI-11 and again
after Phase 07 added `89-chat-selection`.

| | macOS | Android |
|---|---|---|
| Steps walked | 26 | 28 |
| Steps skipped | 0 | 1 — `05-status-viewer`, see UI-10 |
| Exceptions / overflow | 0 | 0 |
| Off-scale gaps | 0 | 0 |
| Unnamed controls | 0 | 0 |
| Tap targets under the floor | **12** | 0 |

The macOS count is four controls, counted three times. `20-chat`, `22-thread`
and `89-chat-selection` are all the conversation, so each meets the same
composer glyphs — Attach, Record voice message and, on the two that follow a
search, the toolbar's Clear button and its unnamed inner box. They are UI-04
and UI-05 below, unchanged and still open; no new control fell under the floor.

Before this phase's fixes the same two runs produced **302** and **457**
findings, including two screens that were a red error page and an unnamed
tappable node over every conversation row on the desktop. The counts below are
the work that closed the gap.

Neither run keeps its screenshots in the repository, and the reason is worth
stating rather than leaving as a gap somebody trips over. Neither run can write
into the checkout: a macOS app is sandboxed, so the walk falls back to its
container's temp directory and prints the path to copy the images from. An
Android run writes into the app's own `code_cache`, and the app is uninstalled
when the run ends — so the images are gone before anyone can pull them.
Locally, an Android run's images are for watching it happen, not for keeping.

CI is where the touch set is kept. The `route-walk` job passes
`--dart-define=WEFT_SHOT_DIR` into the workspace, which a Linux desktop target
can write to, and uploads every image and the findings TSV as the `route-walk`
artifact on every run, pass or fail.

## Fixed in this phase

### High — a screen that did not render

**UI-01. Settings ▸ Devices and Settings ▸ Encryption were a red error page in
demo mode.**
`apps/weft/lib/app/session_providers.dart:41,53` → `deviceManagerProvider` and
`keyBackupProvider` built a `MatrixDeviceManager` over `session.client`, and
demo mode never calls `WeftMatrixSession.initialize()`. Both screens threw
`ProviderException: Bad state: WeftMatrixSession.initialize() has not been
called` in `initState`, and the error widget itself then overflowed by 5172
pixels. Nothing caught it, because nothing had ever opened those two screens
without a homeserver.

Fixed by giving demo mode fixtures for the account the way it already has them
for the rooms: `apps/weft/lib/data/demo_account.dart`. The real path is
unchanged and still fails loudly, which is what its own comment asks for.

### High — a control a screen reader could not use

**UI-02. An unnamed tappable node the size of every conversation row and every
message bubble, on the desktop.**
`apps/weft/lib/features/inbox/mac_shell.dart:422`,
`apps/weft/lib/features/inbox/inbox_shell.dart:366`,
`apps/weft/lib/features/chat/chat_view.dart:2546` → the right-click wrapper is
a `GestureDetector` with only `onSecondaryTapUp`, and any `GestureDetector`
that declares a tap recogniser exports a tappable semantics node. With nothing
to say, it sat over the named row as a silent duplicate: ten on the Mac inbox,
nine more in an open conversation.

Invisible to `test/a11y/semantics_test.dart` because that suite pumps the
*touch* shell, where `_isDesktopPointer` is false and the handler is null.

Fixed with `excludeFromSemantics: true` on all three. The menu loses nothing —
every verb in it is reachable from the row's own actions, and only a pointer
can raise it.

### The reaction spacing complaint

**UI-03. Reactions sat a thumb's width below the message they belong to.**
`apps/weft/lib/features/chat/reaction_bar.dart:131,199` and
`apps/weft/lib/features/chat/chat_view.dart:3149`.

The gap was nobody's decision. A reaction chip paints a ~24pt pill and is
wrapped in `WeftTapTarget` to reach 48 for a thumb, and the tap target centred
its child — so twelve points of transparent padding sat *above* every pill,
between it and the bubble. A reader sees distance; the code says nothing.

Three changes:

- `packages/weft_design/lib/src/tap_target.dart:54` — `WeftTapTarget` takes an
  `alignment`, still centre by default. The reaction chips pass
  `Alignment.topCenter`, so the extra height a thumb needs is spent downwards
  into the margin before the next message, where there was already nothing.
  The target is the same size; only the ink moved.
- `chat_view.dart:3149` — the bar's own gap is now stated:
  `WeftSpace.xxs` above it, and `EdgeInsetsDirectional` so a mirrored thread
  keeps the bar under the edge its bubble is anchored to.
- `reaction_bar.dart:69` — `runSpacing: WeftSpace.xxs`, which was missing
  entirely: a bar that wrapped to a second row had its two rows flush.

Verified in both alignments and in RTL by the regenerated goldens
(`rich_reactions_*`, `a11y_chat_mixed_rtl_*`). The bubble below the reactions
does not move — the total height is unchanged.

### High — an overflow the harness invented

**UI-11. `09-new-group` reported a 107-pixel overflow on Android, and the dialog
was innocent.**
`apps/weft/integration_test/route_walk_test.dart:547` → `boot` pinned
`physicalSize` to 1400×900 and `devicePixelRatio` to 1.0, and left `viewInsets`
alone. The inset is not a fiction the way the size is: it keeps arriving from
the real device, in *that* device's physical pixels, and dividing it by the
pixel ratio the same lines override turned the emulator's soft keyboard into
**800 of the 900 logical pixels** the app had been told it has. The new-group
dialog autofocuses its name field, so the keyboard came up, `AlertDialog` was
given 52 pixels to draw a title and two buttons into, and reported the
difference.

Reproduced in a widget test at a sweep of insets: nothing at 700, an overflow at
800. No device presents 800-of-900 — a phone's keyboard leaves about 600 logical
pixels of 932 — so this was the harness measuring a geometry the app is never
asked for. Fixed by pinning `viewInsets` to zero alongside the size, which is
the other half of pinning the view.

Worth stating what the fix gives up: the walk can no longer see a
keyboard-driven overflow at all. That is the right trade for this file — its
question is the routes, and a suite that fails on a viewport it invented is one
nobody runs twice — but it means "does this screen survive a keyboard" is
unasked here and unasked anywhere else. It is the most concrete thing the
desktop/composer pass could pick up.

Asked since, in the one place it had already gone wrong: the bottom sheets kept
their *fraction* of a screen the keyboard had taken 300 pixels of, so the
attachment preview's caption field and its Send button were drawn under the
keys. `WeftDraggableSheet` (`weft_design/src/components/draggable_sheet.dart`)
insets the sheet by the keyboard and scales the fraction back up so the sheet
keeps its height, and the four draggable sheets — attachment preview, share
target, the Paperless picker and the merge handle picker — go through it.
Measured in pixels at a 300-of-800 inset by
`weft_design/test/draggable_sheet_test.dart` and
`apps/weft/test/attachment_caption_keyboard_test.dart`.

### Off-scale gaps → tokens

Thirteen call sites. Every one was a hand-written double the scan reported by
value and widget chain.

| Was | Now | Where | Note |
|---|---|---|---|
| `6` | `WeftSpace.dense` | `weft_design/src/mac/mac_sidebar.dart:226,227` | sidebar row's side insets |
| `6` | `WeftSpace.dense` | `weft_design/src/mac/mac_sidebar.dart:244` | glyph → label in a sidebar row |
| `6` | `WeftSpace.dense` | `weft_design/src/mac/mac_controls.dart:202` | toolbar search field |
| `6` | `WeftSpace.dense` | `weft_design/src/components/chat_tile.dart:146` | Mac list row's vertical inset |
| `6` | `WeftSpace.dense` | `weft_design/src/components/unread_badge.dart:30` | badge's side padding |
| `6` | `WeftSpace.dense` | `weft_design/src/theme.dart:448,548` | tooltip and dense-field themes |
| `6` | `WeftSpace.dense` | `apps/weft/features/chat/send_network_chip.dart:97` | desktop chip |
| `6` | `WeftSpace.dense` | `apps/weft/features/search/search_screen.dart:534` | provenance tag |
| `5` | `WeftSpace.xs` | `weft_design/src/components/network_rail.dart:363` | rail badge's side padding |
| `5` | `WeftSpace.xs` | `apps/weft/features/search/search_screen.dart` (app bar field) | desktop search field's vertical inset |
| `3` | `WeftSpace.xxs` | `weft_design/src/components/chat_tile.dart:294,482` | title→preview gap, merged-chip glyph gap |
| `3` | `WeftSpace.xxs` | `apps/weft/features/chat/chat_view.dart:2937,3069` | two glyph→label gaps in small chips |
| `3` | `WeftSpace.xxs` | `apps/weft/features/settings/shortcuts_sheet.dart:130` | key cap |
| `1` | `WeftSpace.xxs` | `weft_design/src/components/chat_tile.dart:138` | gap between Mac list rows |

**The scale gained one step**, which is the phase's sanctioned escape hatch
rather than a hardcoded one-off: `WeftSpace.dense = 6`
(`packages/weft_design/lib/src/tokens.dart:31`), the half-step between `xs` and
`sm`. It is there because the same 6 appeared by hand in eight places and all
eight are macOS chrome whose size the system dictates — a 24pt sidebar row is
24pt, and rounding it to `xs` or `sm` changes a control that was measured
against the platform rather than against this scale. Its doc comment says so,
and says it is not a general-purpose step: a phone layout that wants 6 wants
`xs` or `sm` and has not decided which.

The two `1`→`xxs` and `3`→`xxs` changes are the only ones that moved a pixel
beyond a rename. Both tightened a chip's internals by a point and widened the
Mac list's row gap by one; 71 goldens were regenerated and the reaction, inbox
and Mac window diffs reviewed by eye.

## Open

### Medium — six controls smaller than the floor, all macOS, all icon-only (one since fixed)

Every one is a glyph whose semantics node is the glyph rather than a padded
button. None is on the touch shell, where `test/a11y/semantics_test.dart`
already holds the 48dp line.

| # | Surface | Control | Size | Proposed |
|---|---|---|---|---|
| UI-04a | inbox | "Search" (Mac toolbar field) | 93 × 19 | field height to `MacMetrics.fieldHeight` |
| UI-04b | chat | "Clear search" | 13 × 13 | **Fixed 2026-11-17**: `WeftTapTarget` at `MacMetrics.fieldHeight`, now 24 × 24 and named from the catalogue (`macClearSearch`) |
| UI-04c | chat | "Attach" | 20 × 20 | wrap in `WeftTapTarget` |
| UI-04d | chat | "Record voice message" | 16 × 16 | wrap in `WeftTapTarget` |
| UI-05a | search | an unnamed 504 × 20 node | | the field's inner box; grows with UI-04a |
| UI-05b | chat | an unnamed 80 × 19 node | | same shape |

"Clear search" is the Mac toolbar's own field, and it is listed against `20-chat`
rather than the inbox because that is where the walk meets it: `06-search` types
a query, the reset pops the route but does not empty the field, and the clear
button is on the toolbar from then on. The control belongs to the toolbar, not
to the conversation.

Deferred rather than fixed: this phase's remit is spacing, the fix is a
`WeftTapTarget` per control with the golden churn that implies, and the touch
shell — where a *thumb* has to find these — is clean. They belong with the
desktop pass.

### Low

**UI-06. One `Padding` of 5 with no Sennit widget in its chain.**
Reported on the chat screen as `AppBar › ConstrainedBox › DecoratedBox ›
Padding`; no literal 5 exists anywhere in `apps/weft/lib` or
`packages/weft_design/lib`. Almost certainly a pub dependency, which the
local-creation filter cannot exclude. Not actionable until the scanner can
report a file, which needs private inspector API.

**UI-07. `kWeftMinPointerTarget` (28) and `MacPushButton` (24) disagree.**
`packages/weft_design/lib/src/tap_target.dart:24` says 28 is what a pointer
needs; `packages/weft_design/lib/src/mac/mac_controls.dart:333` draws the
platform's own push button at 24 because "a Mac's default button is 22pt".
Both cite the platform and both are defensible — 28 is a *sizing* token for
dense controls, 24 is a button. Read as a floor, 28 made the walk report
thirty-nine findings that were one deliberate decision, so the walk measures
against 24 (WCAG 2.5.8) and says so. Somebody should decide which number
`tap_target.dart` is claiming to be.

**UI-08. Pre-existing analyzer errors in `weft_design`, unrelated to this
phase.** `flutter analyze` at the workspace root reports four, all present at
`HEAD` before this work: `desktop/desktop_tokens.dart:141,142` reference
`WeftSurface.windows` and `WeftSurface.linux`, which the enum does not have
(the file is unexported, unreferenced, and evidently waiting on the
Windows/Linux surfaces); and two unused imports in `mac/mac_panels.dart:4` and
`weft_app_bar.dart:3`. Left alone — fixing the first means deciding what those
surfaces are, which is another phase's question.

**UI-09. Twelve surfaces in the inventory are not walked.** Each has its reason
in the **Walk** column of [`route-inventory.md`](route-inventory.md), and the
number is the count of rows whose Walk cell begins "no": four are pre-session
screens the walk cannot reach from an inbox, five need a real device grant, a
configured endpoint or a homeserver that demands one, two are raised by the OS
or hand off to another app, and one is a confirmation dialog over a screen the
walk already visits, covered by a widget test instead.

**UI-10. The status viewer was skipped on both runs.** The demo fixtures carry
no status broadcast, so the ring row draws nothing and the step has nothing to
tap. Reported by name in the walk's own output rather than passing silently —
`weft: skipped 05-status-viewer`. Fixing it means seeding a status in
`DemoChatRepository`, which is a fixture change and belongs with whoever next
touches that file.

### What Phase 07 added to the walk

**`89-chat-selection`, macOS only.** A mouse drag from inside one bubble to
inside the one below it, photographed with the highlight live. It is the one
state in a conversation that no assertion holds anyone to: the selection wash
is `ColorScheme.primary` at low alpha and it lands on two different fills — the
own bubble's primary tint and the peer's neutral one — so "is the selected text
still readable" has four answers across the two themes. `mac_chat_selection_*`
in `test/goldens/` pins the same scene at the widget level; this step is the
one drawn by a real rasteriser.

Its position in the list is load-bearing for the reason the block above it
gives. A drag is a gesture, and a gesture spent on a control under a live
binding leaves that control unable to take a later tap — so the step sits
*before* `91-chat-preview`, which spends the conversation row's long press, and
after everything that needs to tap a bubble.

### What Phase 09 added to the walk

**`34a-auto-reply` and `34b-auto-reply-editor`, both shells.** The rule list and
the editor behind it. Neither produced a finding on either platform, which is
the answer this register wanted from two screens made almost entirely of
`SwitchListTile`, `ChoiceChip` and a `Slider` — Material's own controls carry
their 48dp padding, and the one place a hand-rolled glyph could have crept in is
the transcript's auto-reply marker, which is a statement rather than a control
and has no tap target to be too small.

**And a harness bug the phase found by tripping over it.** Adding one row to
the settings screen broke the *backup* step of the touch walk — not the new
steps, the existing one below them. `RouteWalker.tapText` scrolled with
`scrollTo`, which stops as soon as the finder matches; in a `ListView` a row is
built a little before it can be seen, so a row landing in the cache-extent band
was found, tapped at a centre outside the viewport, and took nothing. `visible`
fell back to the first match and `warnIfMissed` stayed quiet, so the step
reported "never arrived" about a door nobody had pressed.

That is a walk that can be silently invalidated by any layout change, which is
the opposite of what it is for. `tapText` now calls `bringOnScreen` between the
scroll and the tap — `tester.ensureVisible`, and only when no match is wholly in
the viewport. The touch walk goes from one failure to 31 steps and zero
findings. See the Phase 09 section of [`e2e-matrix.md`](e2e-matrix.md).

### What Phase 10 added to the walk

The walk this file describes could see one set of viewing conditions: 1400×900,
light, English, 1.0×, pinned in `boot()`. Everything below that line — a phone's
width, dark, 2.0× text, a right-to-left window, a Mac window at its minimum and
at full screen — it had never drawn, and the findings in
[`manual-walkthrough.md`](manual-walkthrough.md) are what was behind it: three
`Row`s of buttons that clip their last child at 2.0×, four lists whose floating
button covers their last row, and a Mac window that left the conversation 192
points at 720.

`WEFT_WALK_PASSES` names those conditions and the default is byte-for-byte the
old single pass, so **the CI job below is unchanged** and so are the filenames
in this report. `WEFT_WALK_HOLD` keeps the app alive at the end of a device run
long enough to `adb pull` its screenshots, which is what makes an Android walk
produce artefacts at all — both directories the app can write to on a device go
with it when `flutter test` uninstalls it.

The walk also gained a scroll reset. `_reset` restored the navigator and the
providers but not the inbox's offset, and the touch shell's header scrolls away
with the list — so a part-scrolled inbox has no overflow menu on it. Invisible
at the default pass; at `phone-xl` it failed sixteen consecutive steps with
`Bad state: No element`, which reads exactly like *large text makes Settings
unreachable* and is not. The twelve macOS findings still open below are
reported identically by all four Mac passes, which is a small piece of
corroboration that they are about the controls and not about the window.

## Keeping this true

The walk runs on every push, on `ubuntu-latest`, as the **Route walk & UI
audit** job in `.github/workflows/ci.yaml`. That row draws the *touch* shell,
because Linux resolves to `WeftSurface.touch`; the Mac window's layout needs a
Mac and is a local and pre-release step. The job uploads the screenshots and
the findings TSV as an artifact whether it passes or fails, so a regression is
diagnosable from the run alone and the work list stays visible when it does
not.

A new screen means a row in the inventory and a step in the walk. The walk
fails on a surface it cannot reach, which is the mechanism that keeps both
files honest.
