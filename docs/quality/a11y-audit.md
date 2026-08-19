---
type: analysis
title: Accessibility and RTL Audit
created: 2026-08-19
tags:
  - a11y
  - rtl
  - audit
related:
  - '[[Rich-Content]]'
  - '[[Attachment-Pipeline]]'
  - '[[Calling]]'
  - '[[Notifications]]'
---

# Accessibility and RTL Audit

The state of Weft's UI before Phase 08 changes anything, screen by screen. This
is the work list for the rest of the phase: every remaining task in
`Phase-08-Accessibility-and-RTL.md` should be able to point at findings here and
close them, and the closing task re-reads this file and marks each one fixed or
explicitly deferred.

Findings are exhaustive rather than representative — every occurrence is listed
with a file and a line, because a phase that fixes "the examples" leaves the
long tail behind and the long tail is what a screen-reader user actually hits.

There is also a **[Verified correct](#verified-correct)** section. Several things
that look like findings are not, and a later task that "fixes" them would make
the app worse. They are written down so that does not happen.

## Method

- Every `.dart` file under `apps/weft/lib/features/` (43 files) and
  `packages/weft_design/lib/` (7 files) was read in full.
- Mechanical sweeps over `apps/weft/lib` and `packages/*/lib` for
  `Semantics`, `liveRegion`, `Tooltip`, `Directionality`, `TextDirection`,
  `EdgeInsetsDirectional`, `AlignmentDirectional`, `PositionedDirectional`,
  `Border(left:`, `BorderRadius.only`, `Alignment.center{Left,Right}`,
  `FocusTraversalGroup`, `Shortcuts`, `Actions`, `FocusNode`,
  `supportedLocales`, `localizationsDelegates`, `MediaQuery.textScaler`,
  `MediaQuery.highContrast`, `MediaQuery.disableAnimations`, fixed `height:`,
  and hard-coded `fontSize:`.
- Each directional-looking Material icon in use was checked against
  `matchTextDirection` in the SDK's `icons.dart`, because Flutter mirrors some
  of them for free and wrapping those by hand would double-mirror them.

**Re-run the sweeps with `grep -a`.** Two files in this workspace —
`apps/weft/lib/features/chat/rich_text_view.dart` and
`packages/weft_richtext/lib/src/url_policy.dart` — contain byte sequences that
BSD `grep` classifies as binary, and it then suppresses their matches *silently*
rather than printing "Binary file matches". A plain `grep -rn` over the tree
therefore reports zero hits in both. The first pass of this audit missed
`rich_text_view.dart` entirely for that reason; the counts below are from the
corrected `-a` sweeps. Anything that greps this codebase for a compliance check
— including the CI step task 9 adds — must pass `-a` or it will quietly under-report.

Nothing here has been run against a real screen reader yet. That is the phase's
last task, and this document gets a `Verified with` section then.

## Headline

Six numbers, from the sweeps:

| Thing | Count |
|---|---|
| `Semantics` widgets in the whole app | **6** |
| `liveRegion` / `SemanticsService.announce` | **0** |
| `EdgeInsetsDirectional` / `AlignmentDirectional` / `PositionedDirectional` | **0** |
| `FocusTraversalGroup` / `Shortcuts` / `Actions` / `FocusNode` | **0** |
| `supportedLocales` / `localizationsDelegates` / `flutter_localizations` | **0** |
| `MediaQuery.textScaler` / `.highContrast` / `.disableAnimations` reads | **0** |

`packages/weft_design/test/` exists and is empty — the design system that owns
every colour pair in the app has no test at all, so there is nothing today that
would notice a token regressing below AA.

The single most consequential finding is **CROSS-1**: the app declares no
locales and no localisation delegates, so `Directionality` is unconditionally
LTR. Weft cannot currently be *put into* RTL, on a device or in a test. Every
other RTL finding below is latent until that is fixed, and fixing it is what
turns the rest from theory into failing goldens.

---

## Cross-cutting findings

### CROSS-1 — the app has no localisation surface, so RTL is unreachable

`apps/weft/lib/main.dart:303-318` builds a `MaterialApp` with `title`, `theme`,
`navigatorKey`, `builder` and `home` and nothing else. There is no
`supportedLocales`, no `localizationsDelegates`, and `flutter_localizations` is
not a dependency of `apps/weft/pubspec.yaml`.

Consequences, all of them present today:

- `Directionality` resolves to `TextDirection.ltr` for every locale the device
  can be set to. Switching an Android device to Arabic changes nothing in Weft.
- `Localizations.localeOf` is always `en_US`, so Material's own strings (the
  back button's semantics label, `showTimePicker`'s dial, `SelectableText`'s
  context menu, `showDatePicker`) are always English.
- `intl`'s `DateFormat` is never initialised for a locale. Every
  `DateFormat.Hm()`, `.E()`, `.yMd()`, `.MMMd()` and `.yMMMd().add_Hm()` call —
  `inbox_shell.dart:160-162`, `chat_view.dart:1077,1324,1422`,
  `search_screen.dart:202`, `media_viewer.dart:336`, `devices_screen.dart:433`,
  `edit_history_sheet.dart:118`, `share_target_sheet.dart:678` — formats in the
  default locale and always will.

Fix belongs in task 6 (*Convert every layout to be direction-agnostic*): add
`flutter_localizations`, declare `supportedLocales` including `ar` and `he`,
and wire `localizationsDelegates`.

**Scope note the phase should decide deliberately.** Task 6 also asks that
"`intl` message lookup falls back cleanly for untranslated strings rather than
showing keys". Weft has **no message catalogue at all** — every user-facing
string is a Dart literal (roughly 400 of them across the screens below). There
are therefore no keys to leak, and the clean-fallback requirement is trivially
satisfied by doing nothing. Extracting 400 strings into ARB files is a phase of
its own and is not what M10 is for. Recommendation: add the delegates and the
locales so *direction* and *date formatting* become real, and record string
extraction as deferred with that reason.

### CROSS-2 — nothing in the app is a live region

Zero `liveRegion: true` and zero `SemanticsService.announce` calls. Every
state change that a sighted user learns about by seeing it appear is silent:

| What changes | Where | Task |
|---|---|---|
| A message arrives in the open chat | `chat_view.dart:548-633` | 3 |
| Search result count on every query | `search_screen.dart:76-81` | 4 |
| The unverified-devices banner appears | `unverified_devices_banner.dart:32-45` | 4 |
| Call state: ringing → connecting → connected → ended | `call_screen.dart:296-301` via `callStatusLabel` | 4 |
| Mute / camera / audio-route changes | `call_screen.dart:538-584` | 4 |
| Media viewer page change and staging failure | `media_viewer.dart:281-291`, `:104` | 4 |
| Upload progress and failure | `attachment_bubble.dart:662-673` | 3 |
| Transcription started / finished | `chat_view.dart:795-814` | 3 |
| Bridge health probe result | `bridges_screen.dart:95-110` | 4 |
| Merge accepted / rejected | `merge_screen.dart:67-77` | 4 |

### CROSS-3 — no keyboard model exists

No `FocusTraversalGroup`, no `Shortcuts`, no `Actions`, no `CallbackShortcuts`,
no explicit `FocusNode` anywhere in the app. Two separate problems fall out:

1. **Whole surfaces are unreachable by Tab.** Controls built on
   `GestureDetector` are not focusable at all — they have no `Focus` ancestor
   and no `Semantics(button:)` that Flutter's traversal can land on:

   | Control | File |
   |---|---|
   | Every inbox row | `chat_tile.dart:64-67` |
   | Every network rail item, and the All entry | `network_rail.dart:234-238` |
   | Every accent swatch | `appearance_sheet.dart:165-166` |
   | The "edited" marker (opens edit history) | `chat_view.dart:1414-1418` |
   | The transcript block (long-press re-transcribe) | `attachment_bubble.dart:536-537` |
   | Every image/video/sticker bubble | `attachment_bubble.dart:183-184` |
   | The bubble long-press that opens the action sheet | `chat_view.dart:1191-1195` |

   `InkWell`-based controls (reply chip, reaction chips, file bubble, share
   rows, emoji cells, call buttons) *are* focusable, so the failure is
   inconsistent rather than total — which is worse, because Tab appears to work
   until it silently skips the inbox.

2. **No shortcuts, and Enter is overloaded.** `chat_view.dart:1629-1647` gives
   the composer `minLines: 1, maxLines: 5, textInputAction: TextInputAction.send,
   onSubmitted: (_) => onSend()`. On desktop that means **Enter sends and there
   is no way to type a newline** — `Shift+Enter` is not handled, and a multiline
   composer you cannot put a line break into is a bug independent of a11y.
   There is no next/previous chat, no focus-composer, no focus-search, no
   escape-to-clear-reply, and no shortcuts sheet.

### CROSS-4 — `highContrast`, `disableAnimations` and `textScaler` are never read

- No `MediaQuery.highContrast` read; there is no high-contrast theme variant.
  `WeftTheme.build` (`theme.dart:127-213`) takes `seed`, `brightness`, `amoled`
  and `densityScale` and nothing else.
- No `MediaQuery.disableAnimations` read. Every `AnimatedContainer`,
  `AnimatedSwitcher`, `FadeTransition`, `SlideTransition`, `AnimatedScale`,
  `AnimatedPositioned`, `AnimatedOpacity` and `TweenAnimationBuilder` runs at
  full duration regardless. The staggered inbox entry
  (`inbox_shell.dart:473-496`) and the staggered rail
  (`network_rail.dart:143-188`) are the two that a motion-sensitive user would
  notice most.
- No `MediaQuery.textScaler` read. Nothing is measured against the scaler; the
  fixed boxes in [Text scale](#text-scale-register) are the consequence.

### CROSS-5 — no focus indicator has been designed or checked

`theme.dart` sets `focusedBorder` on `inputDecorationTheme` (line 200-203:
`BorderSide(color: scheme.primary, width: 2)`) and nothing else. Buttons,
list rows, chips and rail items inherit Material's default focus overlay, which
is an alpha wash of `onSurface` — on the AMOLED palette
(`theme.dart:141-150`, base surface `0xFF000000`) that wash is a very dark grey
on black and will not meet 3:1 against the adjacent surface.

### CROSS-6 — no contrast test exists

`packages/weft_design/test/` is empty. There is no `contrastRatio()` helper
anywhere in the workspace and no assertion over any token pair. This is task 2's
whole first bullet.

### CROSS-7 — the golden harness has no accessibility variants

`apps/weft/test/support/golden_harness.dart:167-218` — `pumpWeft` takes `size`,
`mode`, `seed` and four data seams. It hard-codes `themeFor(Brightness.dark)`
(line 209) and wraps the child in a bare `MaterialApp` with no `locale`, no
`MediaQuery` override and therefore no way to state a text scale or a
direction. None of the 20 existing golden pairs covers RTL, a text scale, or
high contrast.

Note for task 8: `themeFor(Brightness.dark)` on line 209 is passed the *platform*
brightness, and `WeftThemeMode.light` overrides it internally — so the existing
light goldens work. Any new variant must go through the same `WeftAppearance`
path rather than building a `ThemeData` directly.

### CROSS-8 — `SnackBar` is the app's only error channel, and it is transient

Ten `showSnackBar` calls across eight files are how the app reports a failed
send (`chat_view.dart:951-956`), a failed transcription (`:808-810`), a failed
save or share (`media_viewer.dart:217-222`), a device action
(`devices_screen.dart:82-86`), a recovery-key outcome
(`security_screen.dart:94-98`), a bridge error (`bridges_screen.dart:156-158`,
`:206-208`), a share result (`share_target_sheet.dart:194-202`), a cleared
preview cache (`link_previews_screen.dart:131-137`) and a call that could not be
placed (`start_call.dart:28-29`).

Flutter's `SnackBar` does not set `liveRegion`, and it disappears on a timer. A
screen-reader user who is reading elsewhere in the tree when one appears gets
nothing, and by the time they navigate to it, it is gone. Every one of those is
the *only* report of an operation that failed.

Whichever task closes CROSS-2 should decide the app-wide answer here rather than
patching ten call sites: a shared `announce()` helper alongside the snackbar, or
a `Semantics(liveRegion: true)` host.

---

## Token layer — `packages/weft_design`

`WeftPalette` (`theme.dart:16-119`) carries 13 colours plus a per-network map.
None has ever been contrast-checked. The pairs below are the ones the audit
expects to fail; the numbers are estimates from the seed defaults and the point
of task 2 is to replace them with computed assertions.

### CONTRAST-1 — fixed brand greens fail on light surfaces

`online`, `callAccept` = `0xFF2ECC71` (`theme.dart:233-234`). Deliberately
fixed, per the doc comment, and correct as a *fill*. But it is used as a
**foreground** in five places:

| Use | File |
|---|---|
| Device trust label text ("Verified") | `devices_screen.dart:399` |
| Backup status label + icon | `security_screen.dart:507` |
| SMS role status label + icon | `sms_screen.dart:205` |
| Bridge login "signed in" dot | `bridges_screen.dart:427` |
| Verification success glyph | `verification_screen.dart:544,625` |
| Login server-resolved tick | `login_screen.dart:292` |

`#2ECC71` against a light theme's `surface` (near-white) is ≈ **1.9:1** — a
clear AA failure for body text and for a 3:1 UI component. Against the dark
surface it is fine. The token needs a light-theme variant, or these call sites
need `onSurface`-derived ink with the green kept for the fill only.

### CONTRAST-2 — white foreground on the accept button

`call_screen.dart:538-584` / `incoming_call_sheet.dart:80-104` pass
`foreground: Colors.white` over `palette.callAccept` (`#2ECC71`) — ≈ **1.9:1**
for a glyph that is the only thing distinguishing accept from decline. The
decline button (`#E5484D` with white) is ≈ 3.9:1 and passes the 3:1 UI-component
bar. The accept button does not.

`call_overlay.dart:212` gets this right (`foreground: Colors.black` on the same
green, ≈ 11:1), which is the fix to copy.

### CONTRAST-3 — alpha-dimmed ink on bubbles

Every one of these dims a foreground that already sits on a coloured fill:

| Ink | Alpha | File |
|---|---|---|
| Timestamp on own/peer bubble | 0.6 | `chat_view.dart:1331` |
| "edited" marker | 0.6 | `chat_view.dart:1411` |
| "Message deleted" | 0.6 | `chat_view.dart:1268` |
| Delivery tick on own bubble | 0.7 | `chat_view.dart:1352` |
| Voice duration | 0.75 | `chat_view.dart:1504` |
| Waveform bars | 0.55 | `chat_view.dart:1491` |
| File size / audio duration | 0.7 | `attachment_bubble.dart:334,402` |
| Transcribe button + label | 0.8 | `attachment_bubble.dart:524,529` |
| Transcript text | 0.9 | `attachment_bubble.dart:558` |
| Upload status line | 0.75 | `attachment_bubble.dart:640` |
| Reply-chip title (stub) | 0.6 | `reply_chip.dart:82` |
| Reply-chip body | 0.55 / 0.8 | `reply_chip.dart:95` |
| Link-preview description | 0.7 | `link_preview_card.dart:192` |
| Link-preview host line | 0.55 | `link_preview_card.dart:206` |

`ownBubbleText` is `scheme.onPrimary` over `scheme.ownBubble` = `scheme.primary`
— a pair Material guarantees at 4.5:1 *undimmed*. At α=0.6 the effective ratio
is roughly 2.3:1. Every row above is a probable AA failure and all of them are
body-size text.

### CONTRAST-4 — harmonised network colours on light surfaces

`_harmonize` (`theme.dart:247-264`) clamps lightness to `0.32–0.58` on light and
`0.52–0.78` on dark. At L=0.58 against a near-white surface the ratio is ≈ 3.4:1.
Used as *text*:

- the network name inside a merged bubble, `chat_view.dart:1234`
- the reply-chip title, `reply_chip.dart:83`
- the link-preview site/host line, `link_preview_card.dart:166`
- "Not encrypted" on the SMS composer bar, `sms_composer_bar.dart:45`

The clamp should be tightened for the light theme, at the token layer, not at
those four call sites.

### CONTRAST-5 — `mergedAccent` as text

`mergedAccent = scheme.tertiary` (`theme.dart:232`). `tertiary` is a *key*
colour in Material 3, guaranteed only against `onTertiary` — not against
`surface`. Used as text at `chat_view.dart:1009` (chat app bar subtitle),
`chat_tile.dart:282` (the "Merged" pill, at `fontSize: 10`) and
`search_screen.dart:207` (the "meaning" tag). All three are small text on a
surface, where the bar is 4.5:1.

### CONTRAST-6 — `Colors.white70` over arbitrary content

`call_screen.dart:265,356` and `media_viewer.dart:337,496,507` put `white70` over
whatever the camera or the sender's photograph happens to be. The media viewer's
caption bar has a scrim (`media_viewer.dart:356-364`) and is fine; the app-bar
title over a bright video frame (`call_screen.dart:263-266`) has only a 0.35
black wash and is not.

### CONTRAST-7 — the divider token is half-alpha

`divider = scheme.outlineVariant.withValues(alpha: 0.5)` (`theme.dart:236`).
Fine as a hairline (a divider is not a UI component under WCAG), but it is also
the border of the composer (`chat_view.dart:1588`), the share sheet's action bar
(`share_target_sheet.dart:706,818`) and the two-pane split
(`inbox_shell.dart:52`) — boundaries a low-vision user relies on. Worth a
deliberate decision rather than an accident.

### SCALE-1 — glyph text sized from a fixed box

Two components derive `fontSize` from their own fixed dimension, so the text
scaler grows the glyph but not the circle it lives in:

- `weft_avatar.dart:67` — `fontSize: inner * 0.36`, inside a `SizedBox(size)`
  at `weft_avatar.dart:112-114`. At 2.0× the initials overflow the avatar.
- `network_glyph.dart:52` — `fontSize: size * (0.36 | 0.5)` inside a
  `width: size, height: size` container (`network_glyph.dart:35-36`). Same.

These are the "absolute `fontSize` used for layout maths" task 2 names.

### Resolved by task 2

The token layer now computes its own contrast. `packages/weft_design/lib/src/contrast.dart`
carries `WeftContrast.ratio/flatten/meets/inkOn/ensure/dim`, and
`packages/weft_design/test/contrast_test.dart` asserts every pair below across
**seven** themes — light, dark, AMOLED, each of those in high contrast, and a
second seed — so a new seed or a Material tone-mapping change is checked rather
than re-blessed. 194 assertions where there were none.

| ID | Resolution |
|---|---|
| CONTRAST-1 | `online` is derived, not fixed: corrected to 4.5:1 against both the surface and a peer bubble. On light it is `#1A7541`, on dark the original `#2ECC71` already passes. All six call sites keep reading `palette.online` |
| CONTRAST-2 | New `onCallAccept` / `onCallDecline` tokens. `inkOn(…, preferred: white)` keeps white where it already passes — decline red is 3.9:1 — and flips only the accept glyph to black. The four `foreground: Colors.white` call sites now read the token |
| CONTRAST-3 | `WeftContrast.dim` / `palette.muted` / `palette.mutedOnBubble` apply the requested alpha and back off only as far as AA needs. All fourteen sites migrated across `chat_view.dart`, `attachment_bubble.dart`, `reply_chip.dart` and `link_preview_card.dart`, each measured against the fill actually behind it — the reply chip's 10% tint and the transcript block's 8% tint included, not the bubble behind them |
| CONTRAST-4 | Split in two: `networkColor` is the **fill** and owes 3:1, `networkTextColor` is the **text** derivation and owes 4.5:1. The four text sites take the second. A single `networkInk` per theme covers every chip glyph — chosen per network, a light rail would have come out half white glyphs and half black |
| CONTRAST-5 | `mergedAccent` corrected against the surface, the peer bubble *and* its own 16% pill tint, which is the background the "Merged" label is actually read on |
| CONTRAST-6 | The call header brings its own scrim (`palette.scrim`, full strength across the text block, fading only under the bottom padding) and its ink is measured against that scrim over pure white — the worst frame a camera can send |
| CONTRAST-7 | Decided rather than inherited: `divider` stays the faint hairline (WCAG 1.4.11 exempts a content divider), and a new `border` token meets 3:1 for the composer edge, the share sheet's action bar, the preview sheet and the two-pane split. Under high contrast `divider` is promoted to `border` |
| SCALE-1 | Both marks opt out of text scaling via `MediaQuery.withNoTextScaling`, with `text_scale_test.dart` pinning them inside their boxes at 0.85×, 1.0×, 1.3× and 2.0× — and asserting the glyph's real *label* still scales, so the opt-out cannot spread |
| CROSS-4 | `WeftTheme.build` takes `highContrast` and `reduceMotion`; `main.dart` reads `MediaQuery.highContrastOf` / `.disableAnimationsOf` once at the root. High contrast goes through Material's own `contrastLevel: 1.0`. Reduced motion is a `WeftMotionTokens` theme extension read as `context.motion`, plus `NoSplash` and a no-op page transition. `weft_design`'s own components are migrated; the app's staggered lists are task 5's |
| CROSS-5 | A `focusRing` token at 3:1 against every surface a control is drawn on — page, field, card, rail. Wired to `focusedBorder` and to a focused `side` on filled/outlined/text/icon buttons, replacing Material's `onSurface` wash that was invisible on AMOLED black |
| CROSS-6 | Closed — the test exists, and `packages/weft_design/test/` is no longer empty |

Two things deliberately *not* changed, with reasons:

- **The focus ring is not required to clear 3:1 against `railSelected`.** Under
  light high contrast the page is near-white and `primaryContainer` is dark;
  no single colour clears 3:1 against both, and the demands point opposite
  ways. The ring is drawn on a control's outer boundary, so the surfaces it
  has to stand out against are the ones *around* the control. Pretending
  otherwise would have moved the failure somewhere less visible.
- **`callAccept` / `callDecline` still hold their fixed brand values.** They
  are the two colours a call is allowed to break the theme with; the ink on
  them moved instead.

---

## Semantics — resolved by task 3

The inbox, the conversation and the composer now say out loud what they have
always shown. Two new files carry the vocabulary and the plumbing:

- `packages/weft_design/lib/src/semantics.dart` — `semanticsSentence`,
  `deliveryStateLabel`, `messageKindLabel`. In the design system for the same
  reason the colour tokens are: an inbox row and a message bubble describe the
  *same* delivery state, and two call sites inventing their own wording is how
  "Delivered" in one place becomes something else in another.
- `apps/weft/lib/app/a11y.dart` — `announce` and `showWeftMessage`. This is
  CROSS-8's app-wide answer: a `SnackBar` sets no live region and disappears on
  a timer, so every report that used to reach `ScaffoldMessenger` directly now
  goes through one helper that puts the words on the screen **and** into the
  announcement queue. Task 4 should route the remaining nine call sites through
  it rather than patching them one by one.

Covered by `apps/weft/test/chat_semantics_test.dart` (15 tests) and
`packages/weft_design/test/semantics_test.dart` (11 tests).

### The rule these follow

Not "wrap everything in one node". A merged node is right for a row that is one
control — the inbox tile, a photo, a file — and wrong for a message bubble,
whose body carries links and mention pills that have to stay individually
reachable. So a bubble gets a **group label** ("Anna Maven, on Telegram") over a
body that keeps its own nodes, and only the metadata row — time and delivery
tick — is merged. Anything that is a control gets `container: true` so it is a
node a reader can land on; anything that is chrome gets `ExcludeSemantics`.

| ID | Resolution |
|---|---|
| A11Y-01 | `_SearchField` announces as a **button** labelled "Search all conversations", not as a text field the user cannot type into. `excludeSemantics` removes the phantom field and the tap action is restated on the node that replaces it |
| A11Y-02 | Both empty states are one `MergeSemantics` node; the glyphs are `ExcludeSemantics` |
| A11Y-03 | The archived toggle carries `Semantics(checked:)`, so "you are looking at archived chats" is distinguishable from "you can" |
| A11Y-04 | `ChatTile` gained a `checked` parameter; the inbox passes `selecting ? picked : null` and the tick state lives on the node that has the conversation's name |
| A11Y-05 | `container: true, excludeSemantics: true` on `ChatTile`. `tap` and `longPress` are restated on the node, because excluding the subtree also excludes the `GestureDetector`'s actions — losing them would have made the inbox unopenable |
| A11Y-06 | The label is now name, networks *by name*, pinned, muted, delivery state, preview, time, unread count |
| A11Y-07 | Pin and mute are in the row's sentence, and each glyph gained a `Tooltip` for the sighted user who does not recognise a 13dp pictogram |
| A11Y-08 | **Half fixed, half deferred.** The state is named for a screen reader (in the row's label) and for a mouse user (a tooltip reading "Read" / "Delivered"). A *shape* difference between the two ticks is a change to the mark itself and belongs to whoever owns the design, not to a semantics pass — see the note below |
| A11Y-09 | The rail's `Tooltip` takes `excludeFromSemantics: true` and the node takes `excludeSemantics: true`, so each filter is announced once rather than three times |
| A11Y-10 | `_announceIncoming` announces the newest message when it changes and is not the reader's own. A live region on the list would have been wrong twice — its label is the whole timeline, and backfilling older history changes it as much as a new message does. The first populated frame is deliberately silent, per conversation: `_open` clears the marker, so clicking through chats on a two-pane desktop does not announce each one's newest message as new |
| A11Y-11 | Group label per bubble: sender, and the leg when the chat is merged |
| A11Y-12 | The no-op search button is **disabled** with the reason in its tooltip. `onPressed: () {}` announced as enabled, took a tap and did nothing, which a reader cannot tell from a tap that failed. Twenty goldens moved for this and only this |
| A11Y-13 | `_EditedMarker` is a labelled button ("Edited at 14:35, show edit history") with its own node, and a tooltip |
| A11Y-14 | `_VoiceContent` announces "Voice message", the duration, and whether a transcript exists or is being made |
| A11Y-15 | `onLongPress` + `onLongPressHint: 'show actions'` on the bubble. The action existed — `GestureDetector` contributes it — but nothing said what it led to |
| A11Y-16 | The composer's field carries a `Semantics(label:)` built from the same `_fieldLabel` the hint uses, so the mode survives the first keystroke |
| A11Y-17 | `_ComposerContextBar` is a live region labelled "Replying to Anna" / "Editing your message" |
| A11Y-18 | The day divider is a `header` node reading "Messages from Aug 18" |
| A11Y-19 | The history spinner is a live region labelled "Loading older messages"; "Beginning of the conversation" is one too |
| A11Y-20 | `MediaAttachment` is one node: kind, caption, and whether the bytes are there yet |
| A11Y-21 | The play badge is inside that node, which says "Video" |
| A11Y-22 | `_FileAttachment` names the family — "PDF", "Archive", "Spreadsheet" — from the same extension table the glyph comes from |
| A11Y-23 | `_AudioAttachment` announces "Audio, <name>, <duration>" as one clause |
| A11Y-24 | The transcript block exposes re-transcribe as a named long-press action |
| A11Y-25 | `Semantics(value: '45%')` on the progress bar; the status line is a live region **only once the upload is terminal**, so a failure is announced and a progress tick is not announced forty times |
| A11Y-26 | The cancel button names its file |
| A11Y-27 | Already good; unchanged |
| A11Y-28 | `_AddReactionChip` is a labelled button with a tooltip |
| A11Y-29 | "Who reacted" is exposed as a named long-press on the chip |
| A11Y-30 | The sender sheet announces the **name**; the handle stays on screen and out of the announcement — a full MXID read character by character is thirty syllables per row |
| A11Y-31 | `ReplyChip` is one node, a button only when there is somewhere to go, and the stub finally says "not loaded yet" |
| A11Y-32 | `LinkPreviewCardBody` is one `link` node: host first, then title and description |
| A11Y-33 | The thumbnail takes `excludeFromSemantics` |
| A11Y-34 | The six quick-reaction cells are buttons labelled "React with 👍" |
| A11Y-35 | The action sheet names the message it acts on |
| A11Y-36 | Emoji cells are buttons |
| A11Y-37 | `_Heading` is a `header` node |
| A11Y-38 | The remove button names its file — eight identical "Remove" buttons was the failure |
| A11Y-39 | `AttachmentSourceThumbnail` is `ExcludeSemantics`; the row beside it already names the file |
| A11Y-40 | "Attach" is a `header` node |
| A11Y-41 | Each version is one `header` node: "Original, 3 Jun 2026 14:32" |
| A11Y-42 | "Edit history" is a `header` node |
| A11Y-43 | The chip's tooltip is "Send via WhatsApp" — the current leg, which is the one fact it existed to state and the one it withheld |
| A11Y-44 | Popup items carry `selected:`, so the tick is not the only signal |
| A11Y-45 | The SMS bar is one node — "Not encrypted. 2 messages · UCS-2" — read before the field it describes |
| A11Y-46 | The banner is a live region |
| A11Y-47 | "Verify" is labelled "Verify your device"; `explicitChildNodes` keeps it reachable under the warning |
| A11Y-127 | Mention pills are buttons with their own node; `@room` announces "mentions everyone" |
| A11Y-128 | The code block is labelled "Code block" |
| A11Y-129 | Headings are `header` nodes |
| A11Y-130 | The bullet is `ExcludeSemantics`; the ordered marker stays. Deliberately **not** a `MergeSemantics` over the row — that would read marker and body as one node and swallow every link and mention pill inside the item |
| A11Y-131 | A hidden spoiler run carries `semanticsLabel: 'Spoiler: …'`. The text is still read out, which is the honest behaviour for a presentation hint; what it is no longer is a surprise |
| A11Y-132 | Already good; unchanged |
| A11Y-136 | `WeftAvatar` announces the person and excludes its children. What a reader actually heard before was the initials — "AM" |
| A11Y-137 | The merge is in the label: "merged across 2 networks: WhatsApp, Signal" |
| A11Y-138 | "online" is in the same sentence |
| A11Y-139 | `NetworkGlyph` announces `network.label`. This is what stops "Sm", "iM", "Gc" and "Mx" being spelled out |
| A11Y-140 | Same fix: the name was always on the enum, it was simply unreachable except through `showLabel`, which nothing passes |
| CROSS-2 (chat half) | New-message, transcription-start and transcription-finish announcements; live regions on the composer context bar, the unverified-devices banner, the history footer and a terminal upload |
| CROSS-8 | Answered app-wide by `showWeftMessage`, and adopted by `chat_view.dart`. The other eight call sites are task 4's |

Four things later tasks should know:

- **`excludeSemantics: true` drops the child's actions too.** Every place this
  pass used it on an interactive widget had to restate `onTap` (and
  `onLongPress`) on the `Semantics` node. A control that goes quiet *and*
  unreachable is a worse bug than the one being fixed; `ChatTile`'s test asserts
  both actions survive precisely because that is the easy mistake here.
- **A control needs `container: true` to be its own node.** Without it a
  `Semantics` merges into the nearest ancestor node — which is how the mention
  pill's label ended up inside the paragraph's, and the reply chip's inside the
  composer bar's live region. Task 5 depends on this: a pill that is not its own
  node cannot be focused.
- **Two live regions are deliberately conditional.** The upload status line is
  live only when `task.state.isTerminal`, and the incoming-message announcement
  is skipped on the first populated frame and for the reader's own sends. An
  unconditional live region on either is worse than none.
- **Twenty golden pairs moved, for one reason.** The only pixel change in this
  task is the disabled search glyph in the chat app bar (A11Y-12) — 147 pixels,
  the same 147 in every image. Everything else here is semantics, which does not
  paint. Task 8 should expect the RTL and scale variants to be the first real
  layout regeneration.

**A11Y-08's remaining half, stated rather than buried.** Read and delivered are
still the same double tick differing only in colour, which fails WCAG 1.4.1 for
a sighted colour-blind user even though it now passes for a screen-reader user
and a mouse user. Every messenger in the category does this, and the fix is a
new mark rather than a code change. Recorded as **open, deferred to design**;
task 9 should carry it forward rather than closing it.

---

## Per-screen findings

### Inbox shell — `features/inbox/inbox_shell.dart`

| ID | Finding | Line |
|---|---|---|
| A11Y-01 | `_SearchField` is an `InkWell` wrapping an `InputDecorator` — a screen reader announces a text field the user cannot type into, and there is no label saying it opens a search screen | `455-468` |
| A11Y-02 | `_EmptyInbox` / `_EmptyDetail` icons carry no semantics and the two Texts are separate nodes | `498-577` |
| RTL-01 | `SafeArea(left: false, bottom: false)` hard-codes the physical left edge; under RTL the inbox column is on the left and the rail on the right, so this skips the wrong inset | `80-84` |
| RTL-02 | `Align(alignment: Alignment.centerLeft)` on the clear-filter chip | `433-434` |
| RTL-03 | `EdgeInsets.fromLTRB` on the inbox header | `293-298` |
| RTL-04 | `EdgeInsets.only(bottom:)` is direction-safe, but the list padding should move to `EdgeInsetsDirectional` for consistency | `98` |
| RTL-05 | Gradient `begin: Alignment.topLeft, end: Alignment.bottomRight` on the empty-detail mark — cosmetic under RTL, listed for completeness | `551-554` |
| SCALE-2 | `_SearchField`'s `child: const SizedBox(height: 20)` fixes the fake field's height while the hint text scales | `465` |
| SCALE-3 | `_EmptyDetail`'s `Container(width: 64, height: 64)` is icon-only and safe; noted so it is not "fixed" | `546-562` |
| KEY-01 | `_StaggeredIn` wraps every row in an `Opacity`/`Transform` animation with no `disableAnimations` guard | `473-496` |
| A11Y-03 | The `PopupMenuButton` items are plain `Text`; the archived toggle's label changes between two states with no selected/checked semantics | `385-425` |
| A11Y-04 | Selection-mode `Checkbox` in the tile's `leading` slot has no label — it announces "checkbox" with no chat name | `111-117` |

### Chat tile — `packages/weft_design/lib/src/components/chat_tile.dart`

| ID | Finding | Line |
|---|---|---|
| A11Y-05 | The merged `Semantics` node exists but is **not exclusive** — no `container: true` / `excludeSemantics: true`, so the title, pin icon, mute icon, delivery icon, preview, time and unread badge are *also* announced as separate nodes underneath it. This is exactly the "five separate nodes" failure task 3 names | `54-60` |
| A11Y-06 | The label omits the message preview, the timestamp, the delivery state and the network *names* (it says "Merged across 3 networks", not which three) | `56-60` |
| A11Y-07 | Pin and mute states are conveyed by a 13dp icon with no label | `131-146` |
| A11Y-08 | Delivery state is a 14dp icon with no label; `read` is distinguished from `delivered` **by colour alone** (`_deliveryIcon` returns `done_all_rounded` for both) | `150-161`, `248-254` |
| SCALE-4 | Unread badge `height: 20` with a `fontSize: 11` child — clips at 2.0× | `206-225` |
| RTL-06 | `alignment: Alignment.center` on the badge is direction-neutral and fine | `215` |

### Network rail — `packages/weft_design/lib/src/components/network_rail.dart`

| ID | Finding | Line |
|---|---|---|
| A11Y-09 | `Semantics(button, selected, label)` on `_RailButton` is **good** and already meets most of task 3's rail requirement. But the enclosing `Tooltip` also contributes its message to the node, so each item is announced twice | `225-233` |
| RTL-07 | `SafeArea(right: false)` hard-codes the physical right edge | `44` |
| RTL-08 | `AnimatedPositioned(left: selected ? -sm : -lg)` — the selection accent bar slides out of the physical left edge, which is the *inside* of the rail under RTL | `265-270` |
| RTL-09 | `Positioned(right: 6, top: 4)` on the unread badge | `285-289` |
| SCALE-5 | `_UnreadBadge` `height: 18` with `fontSize: 10` — clips at 2.0× | `315-333` |
| SCALE-6 | `_RailButton`'s `SizedBox(height: 52)` and the 44/48 selection pill are glyph-sized and safe | `243-263` |
| KEY-02 | Rail items are `GestureDetector`s — not focusable, so Tab never reaches the network filter | `234-238` |
| KEY-03 | Staggered entry animation with no `disableAnimations` guard | `143-188` |

### Avatar and network glyph — `packages/weft_design/lib/src/components/`

Both are drawn on nearly every screen — inbox rows, the chat app bar, search
results, bridges, merge, share targets, the call screen — so one fix here closes
findings on eight screens at once.

| ID | Finding | File · Line |
|---|---|---|
| A11Y-136 | `WeftAvatar` has **no `Semantics` at all**. What a reader actually hears is the initials `Text` — "AB" — because that node is never excluded. It should carry a label (the person, and "merged across N networks" when the ring is drawn) and exclude its children | `weft_avatar.dart:42-150` |
| A11Y-137 | The merged-identity ring and the network badge are purely visual; the merge is signalled three ways for a sighted user and zero ways for a screen reader | `weft_avatar.dart:91-130` |
| A11Y-138 | The `online` dot has no label | `weft_avatar.dart:131-146` |
| A11Y-139 | `NetworkGlyph` has no semantics. The lettermark fallback is the visible failure: a reader announces "Sm", "iM", "Gc", "Mx" literally. This is the root cause behind A11Y-57, A11Y-63, A11Y-88 and A11Y-89 | `network_glyph.dart:28-76` |
| A11Y-140 | `showLabel: true` renders `network.label` beneath the chip — the label exists, it is simply not used in the glyph-only case, which is every case in the app today | `network_glyph.dart:62-75` |
| RTL-38 | `Positioned(right: -1, bottom: -1)` — the network badge stays on the physical trailing corner | `weft_avatar.dart:120-130` |
| RTL-39 | `Positioned(right: 0, top: 0)` — the online dot, likewise | `weft_avatar.dart:131-146` |

### Chat view — `features/chat/chat_view.dart`

| ID | Finding | Line |
|---|---|---|
| A11Y-10 | New messages are appended to the `ListView` with no live region | `548-633` |
| A11Y-11 | Message bubbles have **no `Semantics` at all**. Sender, network, time, delivery state, edited state and reaction summary are each their own node, in visual rather than reading order | `1090-1391` |
| A11Y-12 | The "Search in conversation" app-bar button is `onPressed: () {}` — a no-op announced as an enabled button | `1052-1056` |
| A11Y-13 | The `_EditedMarker`'s tap target is a `GestureDetector` over a `Text` with no button role and no label | `1400-1435` |
| A11Y-14 | `_VoiceContent` announces the duration Text but never "voice message", and does not say whether a transcript exists | `1439-1519` |
| A11Y-15 | The long-press action sheet is the *only* way to reply, react, edit, copy, forward or delete, and long-press is not exposed to a screen reader as a custom action | `1191-1195` |
| A11Y-16 | The composer's `TextField` has a `hintText` and no `labelText` — once text is typed the field has no accessible name, and the mode (reply / edit / network) lives only in that hint | `1629-1647` |
| A11Y-17 | `_ComposerContextBar` states the mode visually; the cancel `IconButton` is labelled but the bar itself is not announced when it appears | `1673-1716` |
| A11Y-18 | The day divider is announced as a bare date between two `Divider`s | `1062-1088` |
| A11Y-19 | `_historyFooter`'s spinner and "Beginning of the conversation" are unlabelled state changes | `683-719` |
| RTL-10 | `Border(left: BorderSide(...))` — the merged-chat network hairline. Under RTL an own-side bubble sits on the left and its hairline stays on the physical left, i.e. on the wrong edge | `1213-1215` |
| RTL-11 | `BorderRadius.only(topLeft/topRight/bottomLeft/bottomRight)` — the bubble tail is computed in physical space and lands on the wrong corner under RTL | `1204-1209` |
| RTL-12 | `EdgeInsets.fromLTRB` on the composer container | `1580-1585` |
| SCALE-7 | `_ChatAppBar` fixes `preferredSize = 64` and `toolbarHeight: 64` around a two-line title — clips at 2.0× | `973`, `978` |
| SCALE-8 | `_VoiceContent`'s waveform maths `((constraints.maxWidth - 60) / 5.5)` reserves a hard-coded 60dp for the duration label, which grows with the scaler — the waveform overruns the bubble at large scale | `1474` |
| SCALE-9 | `maxWidth: 520` bubble constraint is fixed while the text inside scales; at 2.0× a bubble is a narrow column of very tall text. Worth a golden before deciding | `1197` |
| KEY-04 | Enter sends and **Shift+Enter does not insert a newline** — `maxLines: 5` is unreachable from a desktop keyboard | `1634-1635` |
| KEY-05 | No escape-to-clear for reply/edit mode; `_cancelComposerContext` is only reachable by the close button | `856-864` |

### Attachment bubble — `features/chat/attachment_bubble.dart`

| ID | Finding | Line |
|---|---|---|
| A11Y-20 | `MediaAttachment` is a `GestureDetector` over an `Image.memory` with no semantics — a photo announces nothing at all, and the caption (when present) is a separate node | `183-203` |
| A11Y-21 | `_PlayBadge` marks a video visually only | `255-276` |
| A11Y-22 | `_FileAttachment` announces the filename and size but never the kind ("PDF", "archive") that `_iconFor` picks the glyph from | `354-432` |
| A11Y-23 | `_AudioAttachment` announces body and duration as separate nodes with no "audio" role | `285-351` |
| A11Y-24 | `AttachmentTranscript`'s transcript block has `onLongPress: onRetranscribe` with no semantics — the re-transcribe action does not exist for a screen reader | `536-537` |
| A11Y-25 | `UploadProgressBubble`'s `LinearProgressIndicator` has no `Semantics(value:)`; progress and failure are silent | `662-673` |
| A11Y-26 | The upload cancel `IconButton` is tooltipped ("Cancel upload") but does not name the file | `647-656` |
| RTL-13 | `Align(alignment: Alignment.centerLeft)` on the Transcribe button | `513-514` |
| RTL-14 | `Align(alignment: Alignment.centerLeft)` on the Retry button | `675-676` |
| TAP-01 | Transcribe button `minimumSize: Size(0, 28)` | `519` |
| TAP-02 | Retry button `minimumSize: Size(0, 28)` | `681` |
| TAP-03 | Upload cancel `IconButton` with `VisualDensity.compact` and `iconSize: 18` → 40dp | `649-650` |

### Reaction bar — `features/chat/reaction_bar.dart`

| ID | Finding | Line |
|---|---|---|
| A11Y-27 | `ReactionChip`'s `Semantics(button, selected, label: '<emoji> <count>')` is **good** | `85-88` |
| A11Y-28 | `_AddReactionChip` has no semantics and no tooltip — an unlabelled button | `136-163` |
| A11Y-29 | The long-press "who reacted" action is not exposed as a custom action | `56-58` |
| A11Y-30 | `showReactionSendersSheet` announces each `senderId` in full as a subtitle | `203-216` |
| TAP-04 | `ReactionChip` is ≈24dp tall (`vertical: 3` + 13dp text) | `101-104` |
| TAP-05 | `_AddReactionChip` is ≈22dp tall (`vertical: 4` + 14dp icon) | `150-158` |

### Reply chip — `features/chat/reply_chip.dart`

| ID | Finding | Line |
|---|---|---|
| A11Y-31 | No semantics; title and body are two nodes, and the "tap to find it" affordance on a stub is unlabelled | `51-102` |
| RTL-15 | `Border(left: BorderSide(...))` — the quote rule stays on the physical left | `62` |
| RTL-16 | `EdgeInsets.fromLTRB` | `55-60` |
| TAP-06 | ≈31dp tall in the non-compact case | `55-60` |

### Link preview card — `features/chat/link_preview_card.dart`

| ID | Finding | Line |
|---|---|---|
| A11Y-32 | No semantics; host, title, description and second host line are four nodes with no "link" role | `131-217` |
| A11Y-33 | `_Thumbnail` has no label and no `excludeFromSemantics` | `234-259` |
| RTL-17 | `Border(left: BorderSide(...))` | `136` |
| RTL-18 | `EdgeInsets.fromLTRB` | `138-143` |

### Message actions sheet — `features/chat/message_actions_sheet.dart`

| ID | Finding | Line |
|---|---|---|
| A11Y-34 | The six quick-reaction cells are `InkWell`s over emoji `Text` with no `button: true` and no label beyond the glyph name | `112-122` |
| A11Y-35 | The sheet does not announce which message it acts on | `96-101` |
| TAP-07 | Quick-reaction cells are ≈40dp (24dp glyph + `WeftSpace.sm` × 2) | `115-121` |

### Emoji picker sheet — `features/chat/emoji_picker_sheet.dart`

| ID | Finding | Line |
|---|---|---|
| A11Y-36 | `_EmojiWrap` cells are `InkWell`s with no `button: true` | `132-139` |
| A11Y-37 | `_Heading` is a plain `Text`, not a `header: true` semantics node | `99-117` |
| TAP-08 | Cells are ≈34dp (26dp glyph + `WeftSpace.xs` × 2) | `135-138` |

### Attachment preview / source sheets

| ID | Finding | File · Line |
|---|---|---|
| A11Y-38 | Remove button is tooltipped but does not name the file | `attachment_preview_sheet.dart:206-210` |
| A11Y-39 | `AttachmentSourceThumbnail` has no label or `excludeFromSemantics` | `attachment_preview_sheet.dart:270-306` |
| A11Y-40 | The source sheet's "Attach" heading is not a header node | `attachment_source_sheet.dart:49-54` |

### Edit history sheet — `features/chat/edit_history_sheet.dart`

| ID | Finding | Line |
|---|---|---|
| A11Y-41 | Version label and timestamp are two nodes; the body is a third, with nothing tying them together | `104-146` |
| A11Y-42 | "Edit history" is not a header node | `57` |
| RTL-19 | `EdgeInsets.fromLTRB` | `50-55` |

### Send network chip / SMS composer bar

| ID | Finding | File · Line |
|---|---|---|
| A11Y-43 | `tooltip: 'Send via…'` never says which network is *currently* selected — the only indication is the glyph | `send_network_chip.dart:37` |
| A11Y-44 | The popup items announce the network label but not the check mark on the current one | `send_network_chip.dart:39-55` |
| A11Y-45 | "Not encrypted" and the segment count are two nodes, neither associated with the composer field they describe | `sms_composer_bar.dart:37-62` |
| TAP-09 | The chip is ≈34dp tall | `send_network_chip.dart:59-62` |

### Unverified devices banner — `features/chat/unverified_devices_banner.dart`

| ID | Finding | Line |
|---|---|---|
| A11Y-46 | The banner appears in response to a trust change and is never announced — a screen-reader user sending into a room with an unverified device is not told | `32-45` |
| A11Y-47 | The "Verify" button is not associated with the warning text | `70-76` |

### Rich text view — `features/chat/rich_text_view.dart`

This is the file the broken sweep hid. It renders every formatted message body
in the app, so its findings apply to every bubble with markup in it.

| ID | Finding | Line |
|---|---|---|
| A11Y-127 | A mention pill is a `WidgetSpan` wrapping a `GestureDetector` — no `button: true`, no label, and not focusable, so `@room` and every user mention are inert and unannounced as controls | `574-599` |
| A11Y-128 | The code block is a horizontally scrollable region with no label; a reader is not told there is content off-screen | `418-429` |
| A11Y-129 | Headings are rendered as scaled bold paragraphs (`_headingScale`), not as `header: true` semantics nodes | `322-332` |
| A11Y-130 | List markers ("1.", "•") are `Text` siblings of the item body, so each list item is announced as two nodes and the bullet is read aloud as a character | `382-388` |
| A11Y-131 | A spoiler is transparent ink over an opaque background — **deliberate and documented** (`514-547`), and the doc comment is right that Matrix's spoiler is a presentation hint. The a11y consequence to record: a screen reader reads the hidden text aloud immediately. That is the honest behaviour, but it should be a stated decision rather than a surprise | `535-545` |
| A11Y-132 | `_image` renders a custom emoji as its alt text — **good**, and the right call | `556-565` |
| RTL-40 | `EdgeInsets.only(left: WeftSpace.sm)` on the blockquote — the **only** `EdgeInsets.only` with a physical edge in the codebase, and the sweep that reported zero was wrong | `339` |
| RTL-41 | `Border(left: BorderSide(...))` on the blockquote rule — the fourth of these, and the one the first sweep missed | `341-346` |
| RTL-42 | The code block's `SingleChildScrollView(scrollDirection: Axis.horizontal)` resolves its axis direction from `Directionality` and will scroll right-to-left under RTL. Code should almost certainly stay LTR; needs an explicit `Directionality(TextDirection.ltr)` wrapper, not a fix to the scroll view | `418-419` |
| SCALE-16 | List marker `SizedBox(width: ordered ? 26 : 16)` is fixed while the marker text scales — at 2.0× a two-digit ordered marker ("10.") clips | `382-383` |
| CONTRAST-8 | Inline code sets `backgroundColor` to the ink at α=0.12 and leaves the ink at full strength — readable, but the block variant at `_codeBlock` uses the same 0.10 wash over a bubble fill that is already `scheme.primary` on an own message | `415`, `522` |

### Call video view, start call, QR scanner

| ID | Finding | File · Line |
|---|---|---|
| A11Y-133 | `_NoPicture`'s "no camera" glyph is unlabelled, and `RTCVideoView` itself contributes no semantics — a video call is an empty region to a screen reader | `call_video_view.dart:138-162` |
| A11Y-134 | A call that could not be placed is reported only by a `SnackBar` — see CROSS-8 | `start_call.dart:28-29` |
| A11Y-135 | `UnavailableQrScanner` is the scanner every build gets, and `verification_screen.dart:325-341` already renders an honest explanatory paragraph when `available` is false — **good**, and it is also the accessible path, since a camera-based scan is unusable by a blind user regardless. The emoji fallback is the real answer and is already offered | `qr_scanner.dart:31-40` |

### Media viewer — `features/chat/media_viewer.dart`

| ID | Finding | Line |
|---|---|---|
| A11Y-48 | The image itself has no semantics label; the caption is a separate overlay node | `453-476`, `294-300` |
| A11Y-49 | Page changes in the gallery are silent — no "3 of 8" | `281-291` |
| A11Y-50 | The staging spinner and the staging failure are silent | `240-253`, `104` |
| A11Y-51 | `_ViewerTitle` is two nodes (sender, timestamp) | `315-342` |
| RTL-20 | `Positioned(left: 0, right: 0, bottom: 0)` is symmetric and safe — listed so it is not changed | `295-300` |

### Search — `features/search/search_screen.dart`

| ID | Finding | Line |
|---|---|---|
| A11Y-52 | The result count is never announced; task 4 asks for a live region on query change | `76-81` |
| A11Y-53 | The app-bar `TextField` has `hintText` and no `labelText` | `92-101` |
| A11Y-54 | The searching spinner is unlabelled | `103-111` |
| A11Y-55 | `_MethodTag`'s "meaning" / "both" is a bare 10dp word with no explanation of what it qualifies | `229-249` |
| A11Y-56 | Each result is a `ListTile` whose title is the message body and whose subtitle is a `Row` of date + tag — the *chat* and the *sender* are not announced at all, which task 4 requires | `193-223` |
| A11Y-57 | `NetworkGlyph` in the `leading` slot has no label | `194` |
| A11Y-58 | `FilterChip`s announce the network label and selected state via Material — **good** | `126-138` |
| TAP-10 | `FilterChip` is 32dp tall in M3 | `126` |

### Merge — `features/merge/merge_screen.dart`

| ID | Finding | Line |
|---|---|---|
| A11Y-59 | Evidence `Chip`s are separate nodes; the suggestion's score, the two handles and the evidence are five-plus nodes with no grouping | `154-167` |
| A11Y-60 | "Merge" and "Not the same person" do not name *whom* — task 4 asks that accept/reject announce their consequence | `169-183` |
| A11Y-61 | "Unmerge" likewise does not name the handle | `240-243` |
| A11Y-62 | Section titles ("Suggestions", "Merged") are not header nodes | `48-53`, `80-85` |
| A11Y-63 | `_HandleChip`'s `NetworkGlyph` has no label — a reader hears the lettermark ("Sm") | `263` |
| A11Y-64 | The result of a merge/reject is a silent `setState` | `67-77` |

### Bridges — `features/bridges/bridges_screen.dart`

| ID | Finding | Line |
|---|---|---|
| A11Y-65 | The per-bridge `PopupMenuButton` has **no tooltip** — announced as "Show menu" with no bridge name | `375-385` |
| A11Y-66 | Health state is announced only as the login sentence; the probe *completing* is silent | `95-110`, `416-445` |
| A11Y-67 | `QrCard.data` has no semantics label. Mitigated — the raw payload is a `SelectableText` directly beneath it (`604-614`) with a Copy button — but the code itself is invisible and the relationship between them is not stated | `597-599` |
| A11Y-68 | `LinearProgressIndicator` for an in-flight probe is unlabelled | `409` |
| A11Y-69 | The "Add a bridge" dialog's `TextField` uses `hintText` only | `126-132` |
| A11Y-70 | Login-flow step fields use `labelText` + `helperText` — **good** | `562-565` |
| A11Y-71 | The waiting spinner and "Waiting for the other side…" are not a live region | `624-635` |
| RTL-21 | `Align(alignment: Alignment.centerRight)` on the sign-in button | `447-448` |
| RTL-22 | `Icons.login_rounded` **does not** carry `matchTextDirection` and will not mirror | `451` |
| SCALE-10 | The 8×8 status dot is decoration and safe | `421-430` |

### Settings — shared pieces (`features/settings/settings_section.dart`)

| ID | Finding | Line |
|---|---|---|
| A11Y-72 | `PrivacyNotice` is an icon + a `Text` in a `Row`, with no `container: true` and no association with the control it gates. Task 4 requires the warning to be read *before* the toggle; today they are unrelated siblings in a `ListView` | `19-53` |
| A11Y-73 | `SettingsSectionHeader` is not a `header: true` node | `56-90` |
| A11Y-74 | `TextPromptDialog` uses `labelText` + `helperText` — **good** | `179-189` |

### Settings — notifications (`notifications_screen.dart`)

| ID | Finding | Line |
|---|---|---|
| A11Y-75 | `_NetworkRow` puts a `SegmentedButton` in the tile's `subtitle`, so a reader hears "WhatsApp", then three unattached segments "On / Muted / Off" with no statement of which network they belong to | `430-455` |
| A11Y-76 | `_SectionHeader` titles are not header nodes | `630-660` |
| A11Y-77 | The quiet-hours `ListTile`s put the time in `trailing` — announced after the label, which is correct, but "From 22:00" is not stated as an editable value | `298-317` |
| A11Y-78 | `_PushStatus` and `_TestResult` are the outcome of a user action and are never announced | `548-628` |
| A11Y-79 | Every `SwitchListTile` has a title and an explanatory subtitle — **good**, this is the pattern the rest of settings should copy | `208-279` |
| RTL-23 | `Align(alignment: Alignment.centerRight)` on Save gateway | `382-383` |
| RTL-24 | `Align(alignment: Alignment.centerLeft)` on Send test | `398-399` |
| RTL-25 | `Align(alignment: Alignment.centerLeft)` inside `_NetworkRow` | `440-441` |
| TAP-11 | `SegmentedButton` with `VisualDensity.compact` → 32dp | `444` |

### Settings — endpoints, models, MCP, link previews, SMS, appearance

| ID | Finding | File · Line |
|---|---|---|
| A11Y-80 | `_field()` uses `labelText` throughout — **good** | `endpoints_screen.dart:207-224` |
| A11Y-81 | The `PrivacyNotice` gating both switches is not associated with either | `endpoints_screen.dart:119-125` |
| A11Y-82 | `_ModelCard`'s download progress is a bare `LinearProgressIndicator` plus a "x MB of y MB" Text — no `Semantics(value:)`, and completion is silent | `models_screen.dart:174-193` |
| A11Y-83 | The capability icon distinguishing an embedding model from a speech model has no label | `models_screen.dart:147-152` |
| A11Y-84 | The generated API key is a `SelectableText` of an opaque secret in a 12dp monospace run — a screen reader reads it as one unpronounceable word, so it cannot be transcribed by ear | `mcp_screen.dart:126-129` |
| A11Y-85 | The audit log is 30 rows of 11dp monospace `Text` with no grouping; denied entries are marked **by colour alone** | `mcp_screen.dart:243-256` |
| A11Y-86 | `_TunnelTile`'s state icon is colour-coded; the sentence beside it does carry the state, so this is a *mitigated* colour-only signal | `mcp_screen.dart:277-291` |
| A11Y-87 | `CheckboxListTile` scopes have title + subtitle — **good** | `mcp_screen.dart:58-76` |
| A11Y-88 | `SwitchListTile` per network uses `NetworkGlyph` as `secondary` with no label | `link_previews_screen.dart:155-161` |
| A11Y-89 | `_StatusRow` says "On"/"Off" with a `NetworkGlyph` trailing; the glyph is unlabelled and "On" is not tied to the section header that gives it meaning | `sms_screen.dart:196-231` |
| A11Y-90 | `Slider` announces its raw value (`-2`…`2`); the human labels "Compact / Default / Comfortable" only appear in the visual value indicator. Needs `semanticFormatterCallback` | `appearance_sheet.dart:116-127` |
| A11Y-91 | `_SwatchButton`'s `Semantics(button, selected, label: '<name> accent')` is **good** | `appearance_sheet.dart:161-165` |
| A11Y-92 | "Theme", "Accent", "Density" are plain `Text`, not header nodes | `appearance_sheet.dart:52,82,115` |
| RTL-26 | `Align(alignment: Alignment.centerLeft)` on clear-cache | `link_previews_screen.dart:97-98` |
| RTL-27 | `Align(alignment: Alignment.centerLeft)` on the role button | `sms_screen.dart:126-127` |
| RTL-28 | `Align(alignment: Alignment.centerRight)` on Download | `models_screen.dart:242-243` |
| RTL-29 | `EdgeInsets.fromLTRB` in the appearance sheet | `appearance_sheet.dart:34-39` |
| TAP-12 | `_SwatchButton` is 44×44 | `appearance_sheet.dart:170-171` |

### Settings — devices and security

| ID | Finding | File · Line |
|---|---|---|
| A11Y-93 | `_DeviceTile` is `isThreeLine` with a title `Row` (name + "This device" chip) and a two-line subtitle — five nodes for one session, in an order that puts the trust state after the name but the last-seen detail after that | `devices_screen.dart:325-387` |
| A11Y-94 | The trust glyph is colour-coded; `trustLabel` is present as text, so this is *mitigated* | `devices_screen.dart:327`, `409-414` |
| A11Y-95 | `PopupMenuButton(tooltip: 'Device actions')` does not name the device | `devices_screen.dart:367-368` |
| A11Y-96 | The recovery key is a `SelectableText` with `letterSpacing: 1.2` — read as one run, so a user cannot verify it character by character, which is the entire purpose of the confirm step that follows | `security_screen.dart:336-343` |
| A11Y-97 | `_StatusCard`'s state glyph is colour-coded; `backupLabel` is text beside it — *mitigated* | `security_screen.dart:506-538` |
| A11Y-98 | The four-stage `_Stage` machine replaces the body with no announcement, so a stage change is silent | `security_screen.dart:239-245` |
| A11Y-99 | `_ErrorBox` and `_Note` are not announced when they appear | `security_screen.dart:573-630` |
| RTL-30 | `Align(alignment: Alignment.centerLeft)` on the copy-key button | `security_screen.dart:346-347` |
| RTL-31 | `Align(alignment: Alignment.centerLeft)` on sign-out-others | `devices_screen.dart:284-285` |
| RTL-32 | `Icons.logout_rounded` **does not** mirror | `devices_screen.dart:287` |

### Auth — login, verification, gate

| ID | Finding | File · Line |
|---|---|---|
| A11Y-100 | Server, Username and Password fields all use `hintText` with no `labelText` — once typed into, none has an accessible name | `login_screen.dart:125-174` |
| A11Y-101 | `_ErrorBanner` is not announced when a sign-in fails | `login_screen.dart:309-343` |
| A11Y-102 | The busy spinner replaces the button's label, so the button becomes unlabelled while working | `login_screen.dart:189-195` |
| A11Y-103 | `_ServerSummary`'s tick is colour-coded but the sentence carries the state — *mitigated* | `login_screen.dart:289-293` |
| A11Y-104 | `_EmojiCompare` renders 7 emoji, each with its `name` beneath — well labelled, but 14 separate nodes with no grouping and no statement of position ("3 of 7") | `verification_screen.dart:471-502` |
| A11Y-105 | `QrCard.bytes` has **no** semantics label and — unlike the bridge flow — no textual fallback, because the payload is binary. A screen-reader user cannot use the QR path at all and must be steered to emoji comparison | `verification_screen.dart:322` |
| A11Y-106 | Verification state transitions (`waitingAccept` → `askSas` → `done`) swap the body with no announcement | `verification_screen.dart:234-287` |
| A11Y-107 | `_UnlockPrompt`'s error is not announced | `verification_screen.dart:423-432` |
| A11Y-108 | `_Splash`'s spinner is unlabelled; a slow start announces nothing | `auth_gate.dart:100-104` |
| SCALE-11 | `_EmojiCompare`'s `Container(width: 74)` is fixed while the 30dp emoji and the 2-line name both scale | `verification_screen.dart:477-482` |
| SCALE-12 | `_Wordmark`'s 68×68 mark and `_Splash`'s 64×64 mark are icon-only and safe | `login_screen.dart:235-251`, `auth_gate.dart:82-98` |

### Share target sheet — `features/share/share_target_sheet.dart`

| ID | Finding | Line |
|---|---|---|
| A11Y-109 | `_TargetTile` puts a `Checkbox` in `trailing` alongside an `onTap`, giving two adjacent targets for the same row with no distinguishing labels | `641-673` |
| A11Y-110 | A blocked row's reason is in the subtitle — **good** — but `enabled: false` on the `ListTile` means a reader may skip it entirely, so the reason never arrives | `595-603` |
| A11Y-111 | The search field uses `hintText` only | `414-437` |
| A11Y-112 | `_SharedFileStrip` thumbnails have no labels; the filename beneath is a separate node | `926-973` |
| A11Y-113 | The resolve-in-flight state ("Reading 3 files…") and its completion are silent | `494-499` |
| A11Y-114 | "Cannot carry this share" is a section header rendered as plain `Text` inside the list | `579-594` |
| RTL-33 | Four `EdgeInsets.fromLTRB` uses | `336-339`, `408-413`, `699-704`, `811-816` |
| SCALE-13 | `_SharedFileStrip`'s `SizedBox(height: 88)` holds a 64dp thumbnail plus a `labelSmall` line; at 2.0× that line alone is ~24dp and the strip overflows | `935-936` |
| SCALE-14 | `SizedBox(width: 64)` per file column with a `maxLines: 1` ellipsised name — safe | `943` |

### Call — screen, overlay, incoming

| ID | Finding | File · Line |
|---|---|---|
| A11Y-115 | `CallActionButton`'s `Semantics(button: true, label: tooltip)` is **good** — and is the pattern for buttons drawn above the navigator, where a `Tooltip` has no `Overlay` | `call_screen.dart:711-740` |
| A11Y-116 | …except in the audio-route popup, where the child is constructed with `tooltip: null`, producing a `Semantics(button: true, label: null)` — an unlabelled button | `call_screen.dart:641-647` |
| A11Y-117 | `callStatusLabel` changes every second and on every state transition, with no live region | `call_screen.dart:296-301` |
| A11Y-118 | Mute / camera / speaker state is announced only through the button's changing label, which a reader hears only if it happens to be focused | `call_screen.dart:538-584` |
| A11Y-119 | `_ConnectionNote`'s reconnecting and TURN warnings appear and vanish silently | `call_screen.dart:317-363` |
| A11Y-120 | `_VideoRequestPrompt` appears mid-call with no announcement | `call_screen.dart:446-503` |
| A11Y-121 | `_Answer` puts a visible `Text` label under an already-labelled `CallActionButton` — announced twice | `incoming_call_sheet.dart:131-146` |
| A11Y-122 | `MinimisedCallBar`'s hang-up `Semantics(button, label: 'Hang up')` is **good** | `call_overlay.dart:245-259` |
| A11Y-123 | The bar's own `InkWell` (which opens the call screen) is unlabelled | `call_overlay.dart:218-219` |
| A11Y-124 | An incoming call is drawn inline with no focus management — a screen reader is not moved to it | `call_overlay.dart:134-155` |
| RTL-34 | `Positioned(right:, top:)` for the local PiP window | `call_screen.dart:226-230` |
| RTL-35 | `Positioned(top:, right:)` for the heads-up incoming banner | `call_overlay.dart:143-146` |
| RTL-36 | Two `EdgeInsets.fromLTRB` | `call_screen.dart:269-274`, `527-532` |
| SCALE-15 | PiP `width: 108, height: 148` is a video surface — safe | `call_screen.dart:229-230` |
| TAP-13 | `MinimisedCallBar`'s hang-up `InkResponse` is ≈28dp (20dp icon + `WeftSpace.xs` × 2) | `call_overlay.dart:248-258` |
| TAP-14 | `CallActionButton` defaults to 56dp and 44dp in the banner — the 44dp instances are under 48 | `incoming_call_sheet.dart:220,230` |

### Video surface — `services/attachments/video_surface.dart`

| ID | Finding | Line |
|---|---|---|
| RTL-37 | `Positioned(left: 0, right: 0, bottom: 0)` is symmetric and safe | `115-119` |
| A11Y-125 | `VideoProgressIndicator(allowScrubbing: true)` is a draggable control with no semantics value or label | `119` |

### QR card — `features/components/qr_card.dart`

| ID | Finding | Line |
|---|---|---|
| A11Y-126 | Neither constructor takes or emits a semantics label. This is the single shared widget behind both QR surfaces, so task 4's "the QR code carries a semantics label with the copyable payload" is one change here rather than two | `20-52` |

---

## Registers

### Touch target register

Everything measured under 48dp, ordered by severity. Android's guideline is
48×48; iOS's is 44×44, so the 44dp entries fail only the Android check.

| ID | Control | Approx. size | File · Line |
|---|---|---|---|
| TAP-04 | Reaction chip | 24dp | `reaction_bar.dart:101-104` |
| TAP-05 | Add-reaction chip | 22dp | `reaction_bar.dart:150-158` |
| TAP-01 | Transcribe button | 28dp | `attachment_bubble.dart:519` |
| TAP-02 | Upload retry button | 28dp | `attachment_bubble.dart:681` |
| TAP-13 | Minimised-bar hang up | 28dp | `call_overlay.dart:248-258` |
| TAP-06 | Reply chip | 31dp | `reply_chip.dart:55-60` |
| TAP-11 | Notification network segments | 32dp | `notifications_screen.dart:444` |
| TAP-10 | Search network filter chips | 32dp | `search_screen.dart:126` |
| TAP-08 | Emoji picker cells | 34dp | `emoji_picker_sheet.dart:135-138` |
| TAP-09 | Send-network chip | 34dp | `send_network_chip.dart:59-62` |
| TAP-03 | Upload cancel | 40dp | `attachment_bubble.dart:649-650` |
| TAP-07 | Quick-reaction cells | 40dp | `message_actions_sheet.dart:115-121` |
| TAP-12 | Accent swatch | 44dp | `appearance_sheet.dart:170-171` |
| TAP-14 | Call banner accept/decline | 44dp | `incoming_call_sheet.dart:220,230` |
| TAP-15 | The "edited" marker | ≈12dp | `chat_view.dart:1414-1418` |

`_EditedMarker` (TAP-15) is the worst of them: a 10dp italic text run is the
entire tap target for opening the edit history.

### Text scale register

Fixed boxes around text that grows with `MediaQuery.textScaler`. Everything here
needs a 2.0× golden before and after.

| ID | Box | File · Line |
|---|---|---|
| SCALE-7 | Chat app bar, `preferredSize`/`toolbarHeight` 64 around two text lines | `chat_view.dart:973,978` |
| SCALE-4 | Chat tile unread badge, `height: 20` | `chat_tile.dart:206-225` |
| SCALE-5 | Rail unread badge, `height: 18` | `network_rail.dart:315-333` |
| SCALE-2 | Inbox fake search field, `SizedBox(height: 20)` | `inbox_shell.dart:465` |
| SCALE-13 | Shared-file strip, `height: 88` | `share_target_sheet.dart:935-936` |
| SCALE-11 | Verification emoji cell, `width: 74` | `verification_screen.dart:477-482` |
| SCALE-8 | Waveform's hard-coded 60dp allowance for the duration label | `chat_view.dart:1474` |
| SCALE-1 | Avatar initials sized from the avatar box | `weft_avatar.dart:67` |
| SCALE-1 | Network lettermark sized from the glyph box | `network_glyph.dart:52` |
| SCALE-16 | List marker `SizedBox(width: 26 \| 16)` | `rich_text_view.dart:382-383` |
| SCALE-9 | Bubble `maxWidth: 520` (needs judgement, not necessarily a fix) | `chat_view.dart:1197` |

### RTL register — summary counts

| Pattern | Count | Notes |
|---|---|---|
| `Alignment.center{Left,Right}` used for layout | **12** | RTL-02, 13, 14, 21, 23, 24, 25, 26, 27, 28, 30, 31 |
| `Alignment.top/bottom{Left,Right}` in gradients | **12** | Cosmetic; 6 gradient definitions |
| `Border(left: BorderSide(...))` | **4** | RTL-10, 15, 17, 41 — bubble hairline, reply rule, preview rule, blockquote rule |
| `BorderRadius.only` with physical corners | **1** | RTL-11 — the bubble tail |
| `EdgeInsets.fromLTRB` | **15** across 12 files | RTL-03, 12, 16, 18, 19, 29, 33, 36 |
| `EdgeInsets.only(left:/right:)` | **1** | RTL-40 — the blockquote indent |
| `Positioned` with `left:`/`right:` | **6** | RTL-08, 09, 34, 35 + 2 in `weft_avatar.dart:120,132` |
| `SafeArea` with a hard-coded physical edge | **2** | RTL-01, 07 |
| Scroll axis that should be pinned LTR | **1** | RTL-42 — the code block |
| Directional icons that do **not** auto-mirror | **2** | RTL-22 (`login_rounded`), RTL-32 (`logout_rounded`) |

RTL-38 and RTL-39 are the two `weft_avatar.dart` `Positioned` uses, listed under
[Avatar and network glyph](#avatar-and-network-glyph--packagesweft_designlibsrccomponents).

---

## Verified correct

Things that look like findings and are not. A later task should leave these
alone.

1. **Bubble side alignment already mirrors.** `chat_view.dart:1179-1188` uses
   `CrossAxisAlignment.end/start` and `MainAxisAlignment.end/start`, which
   Flutter resolves against the ambient `TextDirection`. Own messages will move
   to the left under RTL for free. Only the tail (RTL-11) and the hairline
   (RTL-10) are computed in physical space.

2. **Most directional icons mirror themselves.** Checked against
   `matchTextDirection` in the SDK's `icons.dart`:
   `Icons.reply_rounded`, `Icons.send`, `Icons.send_rounded`,
   `Icons.forward_rounded`, `Icons.chevron_right_rounded` and `Icons.arrow_back`
   all carry `matchTextDirection: true`. Wrapping them in a `Transform` would
   **double-mirror** them and point them the wrong way under RTL. Only
   `login_rounded` and `logout_rounded` need attention.

3. **Icons that must not mirror, do not.** `play_arrow_rounded`,
   `videocam_rounded`, `call_rounded`, `photo_camera_rounded`,
   `done_all_rounded`, `refresh_rounded`, `merge_rounded` and every
   `SimpleIcons` brand glyph are all created without `matchTextDirection`, which
   is the correct behaviour for a transport control, a camera and a logo. Media
   transport controls conventionally stay LTR even in RTL locales.

4. **`Icons.ios_share_rounded`** (`media_viewer.dart:266`) does not mirror, and
   should not — Apple's share glyph is not mirrored in RTL on Apple's own
   platforms.

5. **The `Semantics` that already exist are the right shape.** `ChatTile`
   (needs `excludeSemantics`, but the label idea is right), `_RailButton`,
   `ReactionChip`, `_SwatchButton`, `CallActionButton` and `MinimisedCallBar`'s
   hang-up all use `button` / `selected` / `label` correctly. They are the house
   style for the rest.

6. **`CallActionButton`'s tooltip fallback** (`call_screen.dart:736-740`) is
   correct and subtle: a `Tooltip` needs an `Overlay`, and `CallOverlay` draws
   above the navigator where there is none, so the label lives on the
   `Semantics` and the `Tooltip` is added only when an `Overlay` exists. Any
   other button drawn above the navigator must do the same.

7. **Colour is never the sole signal, in four places that could easily have got
   it wrong.** The reaction chip outlines the reader's own reaction as well as
   tinting it (`reaction_bar.dart:107-113`); the merged chat is signalled three
   ways (ring, glyph strip, label); the bridge login dot sits beside a sentence
   naming the state; the device trust glyph sits beside `trustLabel`. The one
   real colour-only signal found is **A11Y-08** (read vs delivered) and
   **A11Y-85** (denied audit entries).

8. **All 26 `EdgeInsets.only(top:/bottom:)` uses are direction-neutral** and
   need no change. Exactly one `EdgeInsets.only` in the codebase takes a
   physical edge — `rich_text_view.dart:339` (RTL-40) — and it is the only one
   worth touching.

9. **`media_viewer.dart:295-300` and `video_surface.dart:115-119`** use
   `Positioned` with both `left: 0` and `right: 0`, which is a stretch rather
   than an edge anchor and is direction-safe.

---

## Work list

Findings mapped to the phase's remaining tasks, so nothing here is orphaned.

| Task | Closes |
|---|---|
| 2 — tokens, contrast, typography | CROSS-4, CROSS-5, CROSS-6, CONTRAST-1…8, SCALE-1 |
| 3 — inbox, chat, composer semantics | A11Y-01…47, 127…132, 136…140, CROSS-2 (chat half), CROSS-8 |
| 4 — remaining screens | A11Y-48…126, 133…135, CROSS-2 (rest), CROSS-8 |
| 5 — keyboard | CROSS-3, KEY-01…05, A11Y-127 (mention pills must be focusable) |
| 6 — direction-agnostic layout | CROSS-1, RTL-01…42 |
| 7 — test suite | CROSS-6, TAP-01…15 (via the tap-target guidelines) |
| 8 — golden variants | CROSS-7, SCALE-2…16 |
| 9 — run everything, close the audit | this document's status column |
| 10 — real assistive technology | the `Verified with` section, appended then |

Totals: **140 semantics findings**, **42 RTL findings**, **16 text-scale
findings**, **15 touch-target findings**, **8 contrast findings**, **5 keyboard
findings**, **8 cross-cutting findings** — 234 in all.

## Status

Closed so far: the token layer (task 2 — see
[Resolved by task 2](#resolved-by-task-2)) and the inbox, chat and composer
semantics (task 3 — see
[Semantics — resolved by task 3](#semantics--resolved-by-task-3)). One finding,
**A11Y-08**, is closed for a screen reader and explicitly deferred to design for
its visual half.

Everything else is **open**. Task 9 re-reads this file and marks each remaining
one fixed or deferred with a reason.

The work list's task 3 row originally read "A11Y-01…31, 34…47", which orphaned
A11Y-32 and A11Y-33 — the link preview card, a chat surface with no other task
claiming it. They were fixed here and the row corrected. CROSS-8 moved to task 3
too, since it asked for one app-wide answer and task 3 is where the first call
site needed it.
