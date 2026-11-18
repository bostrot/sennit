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

The state of Weft's UI before the accessibility work changed anything, screen by
screen. This is that work's list: every fix should be able to point at a
finding here and close it, and each one is marked fixed or explicitly deferred.

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

Nothing in the findings below was run against a real screen reader — they are
what reading the code and running the suite found. What a screen reader found on
a device is in [Verified with](#verified-with), which is the phase's last task
and which contradicts this half of the document in five places.

## Headline

Six numbers, from the sweeps:

| Thing | Count |
|---|---|
| `Semantics` widgets in the whole app | **6** — closed by tasks 3 and 4 |
| `liveRegion` / `SemanticsService.announce` | **0** — closed by tasks 3 and 4 |
| `EdgeInsetsDirectional` / `AlignmentDirectional` / `PositionedDirectional` | **0** — closed by task 6 |
| `FocusTraversalGroup` / `Shortcuts` / `Actions` / `FocusNode` | **0** — closed by task 5 |
| `supportedLocales` / `localizationsDelegates` / `flutter_localizations` | **0** — closed by task 6 |
| `MediaQuery.textScaler` / `.highContrast` / `.disableAnimations` reads | **0** — closed by tasks 2, 8 and 9 |

`packages/weft_design/test/` exists and is empty — the design system that owns
every colour pair in the app has no test at all, so there is nothing today that
would notice a token regressing below AA. It holds **259 tests** now, and task 9
put the package into CI, where it had never run.

The single most consequential finding was **CROSS-1**: the app declared no
locales and no localisation delegates, so `Directionality` was unconditionally
LTR and Weft could not be *put into* RTL, on a device or in a test — which made
every other RTL finding below latent. Task 6 closed it, and closing it is what
turned the rest from theory into something a golden can fail on.

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

## Semantics — resolved by task 4

Everything outside the conversation: settings, bridges, merge, search, share,
auth, the media viewer and the surfaces a call puts on top of the app. Eighty
findings, and between them only two failures repeated over and over.

**A button that does not say what it acts on.** Four suggestion cards give four
buttons reading "Merge"; a contact with three legs gives three reading
"Unmerge"; five model cards give five reading "Download", one of which is a
1.5 GB file; six sessions give six popup menus called "Device actions" over a
menu whose last item signs one out. The word is right for someone who can see
which row it is in and useless to everyone else.

**A result nobody is told about.** A merge, a health probe, a verification step,
a share and a stage change all report themselves by redrawing a list. That is a
complete report for someone watching and no report at all for someone
listening — the reader is left standing on whatever moved up into the gap.

Two pieces of shared plumbing came out of them, which is the reason this is one
task rather than eighty:

- **`NamedButton`** (`apps/weft/lib/app/a11y.dart`). A bare
  `Semantics(label:)` around a Material button does *not* reliably rename it:
  the button forms its own node from its own child, so depending on the button
  the annotation is either dropped or left speaking beside the label it was
  meant to replace. Owning the node means excluding the subtree, and excluding
  the subtree takes the tap action with it. Restating that action is the part a
  hand-written copy eventually forgets, so it lives in one widget. This was
  found by a failing test, not by reading: the first pass wrapped six buttons
  and renamed four of them.
- **`PrivacyGatedTitle`** (`features/settings/settings_section.dart`). Same
  shape, other direction: a `SwitchListTile` forms its own node, so a hint
  wrapped *around* the tile becomes a second node the reader meets separately
  from the switch it qualifies. Given as the tile's `title` it merges, and the
  cost of the toggle arrives with the toggle.

`spelledOut` joined `weft_design`'s semantics vocabulary for the two strings the
app shows once and never again — the MCP API key and the recovery key. Both were
one monospace run, which an engine announces as a single unpronounceable word,
so the two screens whose entire purpose is *write this down* were the two a
blind user could not complete.

| ID | Resolution |
|---|---|
| A11Y-48 | The picture is one `image` node — kind, sender, caption — and the caption bar overlaid on it is `ExcludeSemantics`, since those words are now the tail of the picture's own label |
| A11Y-49 | A swipe announces "3 of 8" and what landed. Position first: it is the fact a swipe is asking about |
| A11Y-50 | The staging spinner is a live region ("Downloading this attachment"); a staging failure is a live region in place of the picture that never arrived |
| A11Y-51 | `MergeSemantics` — a name and a date are not two stops on the way out of an app bar |
| A11Y-52 | A visible summary line above the list, and it is the live region. Visible rather than a bare announcement because there *is* something to point at, and a user who missed it can navigate back to it. It is also the empty case, which is why the list draws nothing then — a summary line *and* a centred "Nothing matched" is one sentence for a sighted user and two announcements for a reader |
| A11Y-53 | `Semantics(label: 'Search all conversations', textField: true)`, the same pattern as the composer: a hint is gone at the first keystroke |
| A11Y-54 | "Searching" |
| A11Y-55 | The tag's sentence is in the result's label, and in a `Tooltip` for the sighted user. "meaning" qualifies the *match*, and nothing on the row said so |
| A11Y-56 | One node per result: chat, sender, network, body, date and how it was found. **This needed a data change** — `SearchResult` gained `senderName` and `chatTitle`, both of which had been on the index row since it was written and read back by nobody. The row showed a message with no statement of who said it or where, and the sender is now visible in the subtitle as well |
| A11Y-57 | Silenced with `semanticsLabel: ''`; the network is named in the sentence |
| A11Y-58 | Already good; unchanged |
| A11Y-59 | The proposal is one statement — both handles, the confidence and the evidence — over two buttons that stay their own nodes |
| A11Y-60 | `NamedButton`: "Merge Anna Maven on WhatsApp with Anna on Signal into one conversation", and the rejection says what keeping them separate means |
| A11Y-61 | Likewise, per leg, naming the contact it leaves |
| A11Y-62 | `_SectionTitle` is a `header` node |
| A11Y-63 | Inside the proposal's merged node; the handle's name and network are in the sentence |
| A11Y-64 | `_decide` announces the outcome after every merge, rejection and unmerge |
| A11Y-65 | "Actions for the WhatsApp bridge" |
| A11Y-66 | `_probe` announces what it found — `_reachedLabel` turns a probe into "connected as +44…", "reachable, but not signed in yet", "2 of 3 accounts connected". This screen is only ever open to answer "is it working?" |
| A11Y-67 | The card's label names the flow and points at the copyable code below it, which is the part that actually works |
| A11Y-68 | "Checking the WhatsApp bridge" |
| A11Y-69 | Labelled |
| A11Y-70 | Already good; unchanged |
| A11Y-71 | One live node over the spinner and its caption, and `_done` / `_failed` are live too — this step ends when the *other* device does something |
| A11Y-72 | Two halves. `PrivacyNotice` is one node prefixed "Privacy warning", because the red box and the shield glyph are the entire signal that this is not more explanatory copy. And `PrivacyGatedTitle` puts the one sentence that would stop someone onto the switch itself, as a hint — a reader who lands on the toggle directly never passes the notice at the top of the list |
| A11Y-73 | One `header` node carrying title and subtitle |
| A11Y-75 | Each segment announces "WhatsApp: Muted". Nine loose segments reading On/Muted/Off, and no way to tell which three belong to the row you are in |
| A11Y-76 | `_SectionHeader` was a byte-identical private copy of `SettingsSectionHeader` — **deleted**, and its six call sites now use the shared one. Fixing the same finding twice in two places is how the two drift |
| A11Y-77 | `_QuietHourTile`: label "Quiet hours start", value "22:00", hint "change the time". "From 22:00" read as a label is a statement about the screen rather than something a reader knows they can change |
| A11Y-78 | Both are live regions, and `_TestResult` says "Delivered" or "Blocked" in words — the two differ by a tick and a panel colour otherwise |
| A11Y-79 | Already good; the pattern the rest of settings copies |
| A11Y-80 | Already good; unchanged |
| A11Y-81 | `PrivacyGatedTitle` on both switches, naming what each one sends |
| A11Y-82 | `Semantics(value: '43%')` on the bar — a *value*, not a live region, since a download reports progress many times a second. The **end** is what is announced: installed and failed are both live |
| A11Y-83 | "Search model" / "Speech model" |
| A11Y-84 | `spelledOut`, with Copy named as the shorter road |
| A11Y-85 | Every row is prefixed "Allowed" or "Denied". The word goes first because that is the one a reader skimming thirty rows is listening for, on the log whose whole job is to show an agent being refused |
| A11Y-86 | The colour-coded glyph is `ExcludeSemantics`; the sentence beside it already carries the state |
| A11Y-87 | Already good; unchanged |
| A11Y-88 | Silenced — the tile is one merged node and the title beside the glyph is already the network's name, so a labelled glyph read "WhatsApp, WhatsApp" |
| A11Y-89 | One node: "SMS is on. Weft is your messaging app." "On" was a word with no subject, and the only thing supplying one was a 22dp lettermark at the far end of the row |
| A11Y-90 | `semanticFormatterCallback` — the human words existed already and lived only in the visual value indicator, the one place a reader cannot go |
| A11Y-91 | Already good; unchanged |
| A11Y-92 | `_SheetHeading` — `header` nodes |
| A11Y-93 | One node per session, in the order the facts matter: name, whether it is this device, trust, then last-seen. `explicitChildNodes` is *not* used — the shown text is excluded piece by piece so the popup menu stays its own reachable node |
| A11Y-94 | Glyph excluded; `trustLabel` carries the state |
| A11Y-95 | "Actions for Weft on Pixel" |
| A11Y-96 | `spelledOut`. This is the one string in Weft a user must reproduce character for character and will never be shown again |
| A11Y-97 | Unchanged, and still mitigated: `backupLabel` sits beside the glyph in words |
| A11Y-98 | `_goTo` moves the stage *and* says where the user now is. Each stage replaces the whole body, and the focus stays wherever the old one left it |
| A11Y-99 | `_ErrorBox` is a live region — a mistyped recovery key leaves the field, the button and the screen exactly as they were apart from this box. `_Note` is named "Suggestion", since the grey box and the info glyph are the whole signal that it is advice |
| A11Y-100 | All three labelled |
| A11Y-101 | Live, and named "Sign-in failed" — the banner appears while the focus is still on the button that has apparently just done nothing |
| A11Y-102 | The label outlives the text it is made of: the spinner replaces the button's child, so for the seconds that matter most it was announced as "button" |
| A11Y-103 | Unchanged; mitigated |
| A11Y-104 | One node per cell, with its position: "3 of 7, Dog". The order is half of what the user is being asked to check, and "do these appear, in this order" was a question a reader could not answer |
| A11Y-105 | Labelled, and the label steers to emoji comparison. Unlike the bridge flow there is no text fallback to point at — the payload is two ed25519 keys and a shared secret — so the honest label names the path that works instead of pretending this one does |
| A11Y-106 | `verificationStateLabel` for all nine states, announced from `onUpdate`. Several of the transitions are driven by the *other* device rather than by anything the user here did |
| A11Y-107 | Live |
| A11Y-108 | "Starting Weft". A slow start was a blank screen with an unlabelled spinner, which is a screen with nothing on it at all |
| A11Y-109 | One node for the row, with the checkbox kept reachable and named — "Also send to Anna" / "Remove Anna from this share". Adding a target and opening one are different acts and a reader needs both; it was the *unlabelled* pair of them that was the bug |
| A11Y-110 | The reason is in the row's label, so `enabled: false` skipping the tile no longer skips the only useful thing on it |
| A11Y-111 | Labelled |
| A11Y-112 | `MergeSemantics` per file — a thumbnail with no label and a name beneath it were two nodes and only one said anything |
| A11Y-113 | The summary line is a live region, so both "Reading 3 files…" and what those files turned out to be arrive |
| A11Y-114 | `header` |
| A11Y-115 | Already good; the pattern for buttons above the navigator |
| A11Y-116 | The button inside the audio-route popup was built with `tooltip: null`, producing `Semantics(button: true, label: null)`. It now carries the route |
| A11Y-117 | Announced **on state transition**, not as a live region. `callStatusLabel` carries the running duration and is rebuilt once a second; a live node there would announce the call's length sixty times a minute and drown everything else. A test pins that it stays quiet while the ticker runs |
| A11Y-118 | `_announceChanges` — mute, camera and audio route, each said once when it changes. The button's changing label reached only whoever happened to be focused on it, and the one thing worth knowing about a muted microphone is that it is muted while you are talking into it |
| A11Y-119 | Reconnecting and recovered are announced; `_Note` is one node with its glyph excluded |
| A11Y-120 | Live. It appears mid-call, because of something the far end did, and asks whether this device keeps sending a picture of the room you are in |
| A11Y-121 | The caption under the button is `ExcludeSemantics` — the button already carries the word |
| A11Y-122 | Already good; unchanged |
| A11Y-123 | The bar is a button: "Open the call with Anna, 1:04". It was the way back into the call and said so nowhere |
| A11Y-124 | An assertive announcement naming the caller and the call's kind, fired from `CallOverlay` when a call starts ringing. **Not focus management**, which is the honest answer: the sheet is drawn inline rather than pushed, so there is no route change to move focus with, and moving focus by hand into a surface the user has not asked for is its own bug. The announcement is what a route change would have given them |
| A11Y-125 | `slider` with a value — "0:14 of 1:32". A draggable control with no name at the bottom of a video |
| A11Y-126 | One optional `semanticsLabel` on the shared card, defaulted rather than required so a caller cannot leave a code silent by forgetting it — which is how it was silent before |
| A11Y-133 | `RTCVideoView` contributes no semantics at all, so a video call was a screen-sized hole. Labelled "Your camera" / "Video from the other person"; `_NoPicture` says "No picture yet" |
| A11Y-134 | Routed through `showWeftMessage` |
| A11Y-135 | Already correct; unchanged |
| CROSS-2 (rest) | Live regions on the search summary, the bridge login wait and its two outcomes, push status, the test-notification result, model install and failure, the sign-in banner, the unlock error, the recovery-key error, the share summary and the video-request prompt. Announcements for merges, probes, verification steps, media page changes, call state, and an incoming call |
| CROSS-8 | **Closed.** The remaining eight call sites — media viewer, devices, security, bridges (×2), share, link previews and `startCall` — all go through `showWeftMessage` now. The share sheet is the one exception to the letter of it: it pops as it reports, so it keeps its captured `ScaffoldMessenger` and announces separately |

One finding from another task was fixed here because it was one line away:
**SCALE-13**, the share sheet's `SizedBox(height: 88)` holding a 64dp thumbnail
and a caption that scales — it is now measured from `textScalerOf`.

Four things later tasks should know:

- **A `Semantics` wrapper does not rename a Material button.** Use
  `NamedButton`. This is not a style preference: the first pass here wrapped six
  buttons in `Semantics(label:)` and a test found that four of them kept their
  old name, one gained a second node saying both, and one lost the label
  entirely. The behaviour depends on how the particular button builds its child.
- **A hint on a `SwitchListTile` has to go *inside* it.** Same cause. Use
  `PrivacyGatedTitle`, or put the annotation in a slot the tile merges.
- **Task 5's keyboard pass inherits three group nodes** — the device tile, the
  share target row and the merge proposal — that use a label over children kept
  deliberately reachable. Those children are what Tab has to land on; a pass
  that converts them to `excludeSemantics` for tidiness would make three screens
  unusable by keyboard.
- **`test/support/semantics_probe.dart` is where the assertions live now.**
  `labelsIn`, `liveRegionsIn` and `watchAnnouncements`, extracted from
  `chat_semantics_test.dart` and used by four suites. `liveRegionsIn` matters
  more than it looks: "the words are on screen" and "the words will be read out
  when they change" are different claims, and only the second is what a live
  region is for.

Covered by `apps/weft/test/screen_semantics_test.dart` (14 tests) plus
additions to `media_viewer_test.dart` (2), `call_screen_test.dart` (3) and
`packages/weft_design/test/semantics_test.dart` (4).

---

## Keyboard — resolved by task 5

CROSS-3 was two findings sharing one number, and they needed different answers.

**Half of the app was not focusable.** Seven controls were built on
`GestureDetector`, which Tab does not stop on, while the `InkWell`-based
controls beside them were reachable — so Tab appeared to work right up until it
silently skipped the entire inbox. Tasks 3 and 4 had already given each of them
a correct `Semantics` node, and that is exactly the trap: the semantics tree is
what a screen reader walks and the focus tree is what Tab walks, and they are
different trees. A labelled control nothing can land on is still unusable.

**Nothing was bound, and the one key that was bound was wrong.** No shortcuts of
any kind, and `textInputAction: TextInputAction.send` meant the embedder called
`performAction` for Shift+Enter exactly as it did for Enter — so a `maxLines: 5`
composer had no reachable second line.

### What was built

- **`packages/weft_design/lib/src/focus.dart` — `WeftFocusable`.** One widget
  carrying all three things a control needs at once, because doing two of the
  three is the failure mode: a `Focus` so Tab lands on it, a ring painted
  *outside* its bounds in `palette.focusRing` so landing is visible, and
  `ActivateIntent`/`ButtonActivateIntent` wired to the tap so landing does
  something. It also owns the semantics recipe tasks 3 and 4 established —
  `container: true`, `excludeSemantics: true`, tap and long-press restated —
  because splitting that recipe across two widgets is how the next call site
  gets one half of it.
- **`apps/weft/lib/app/shortcuts.dart`.** The intents, the bindings table, the
  app-wide `Shortcuts`/`Actions` scope installed above the navigator, the
  composer's `Enter`/`Shift+Enter` map, and `ComposerHandle`.
- **`apps/weft/lib/features/settings/shortcuts_sheet.dart`.** The sheet,
  rendered from the same table that builds the map.

### Findings closed

| ID | Resolution |
|---|---|
| CROSS-3 (part 1) | All seven `GestureDetector` controls are now `WeftFocusable`: the inbox row (`chat_tile.dart`), every rail item and the All entry (`network_rail.dart`), every accent swatch (`appearance_sheet.dart`), the edited marker and the message bubble (`chat_view.dart`), the transcript block and every image/video/sticker bubble (`attachment_bubble.dart`) |
| CROSS-3 (part 2) | Five app-wide bindings, three composer-local ones, a sheet listing all eight — see the table below |
| KEY-01 | `_StaggeredIn` reads `context.motion`, so the inbox appears rather than marching in under `MediaQuery.disableAnimations` |
| KEY-02 | Rail items are focusable and Tab reaches the network filter |
| KEY-03 | Already closed by task 2 — `_RailEntry` was migrated to `context.motion` when the token layer landed, and the audit's line reference predates that. Verified, not re-fixed |
| KEY-04 | `Shift+Enter` inserts a newline at the caret; `Enter` sends. Bound around the field so the framework marks the key handled and the embedder never forwards it, which is the only place the two can be told apart |
| KEY-05 | `Escape` leaves reply and edit mode. Entering either now also puts the caret in the composer, which is what makes the key reachable at all |
| A11Y-127 | Mention pills are `WeftFocusable`, so `@room` and every user mention is a tab stop as well as a node |

### The bindings

| Action | Keys | Where it is bound |
|---|---|---|
| Next conversation | `Alt+↓`, `Ctrl/Cmd+PageDown` | app-wide |
| Previous conversation | `Alt+↑`, `Ctrl/Cmd+PageUp` | app-wide |
| Search all conversations | `Ctrl/Cmd+F`, `Ctrl/Cmd+K` | app-wide |
| Write a message | `Ctrl/Cmd+Shift+M` | app-wide |
| Keyboard shortcuts | `Ctrl/Cmd+/` | app-wide |
| Send | `Enter` | the composer |
| New line | `Shift+Enter` | the composer |
| Cancel reply or edit | `Escape` | the conversation |

### Five things later tasks must not get wrong

- **The annotation goes *outside* the detector, not under it.** Both a screen
  reader and `tester.getSemantics` resolve a node by walking *up* from a
  widget's first render object, so a `Semantics` buried beneath
  `FocusableActionDetector`'s `MouseRegion` is a node nothing asking about the
  control ever finds — the label reads as absent while sitting right there in
  the tree. Four `ChatTile` tests caught this; the first arrangement passed
  analysis and failed every one of them.
- **`onActivate` is not `onTap`.** A message bubble opens its action sheet on
  long-press, and a keyboard has no long-press — but binding the sheet to
  `onTap` so Enter would reach it puts a menu in front of everyone who touches
  a message. The two are separate parameters for that one case, and the bubble
  is the only caller that needs them apart.
- **A shortcut that cannot act must report itself *disabled*, not do nothing.**
  A disabled `Action` lets `Shortcuts` return the key as unhandled, so it
  carries on to whoever else wants it. This is what keeps Escape over a dialog
  closing the dialog rather than clearing a reply nobody can see, and what
  keeps Alt+↓ on a one-pane window from being eaten by a pane that is not on
  screen. `WeftGuardedAction` is the shared answer.
- **Nothing app-wide may be bound to an unmodified key.** Enter and Escape are
  Weft's, but they are bound *inside* the conversation and fall through when
  they have nothing to do. `keyboard_test.dart` asserts this over the map
  itself rather than by example, because the rule is what stops a future
  binding from swallowing a character mid-sentence.
- **Traversal is ordered, not reading order.** `OrderedTraversalPolicy` with
  explicit `NumericFocusOrder`s — rail, list, detail, then composer — because
  reading order is derived from where things sit on screen and would put the
  rail last the moment task 6 puts the app into Arabic. Task 6 inherits this
  working; it should not need to touch it.

Two things the audit did not have. **Reply and edit never focused the composer**
— `autofocus` on a `TextField` is read once, when its focus node first attaches,
and the composer is on screen long before anyone long-presses a bubble, so
flipping the flag to true did nothing at all. That was invisible until Escape
needed the focus to be somewhere. And the media bubble carried *two* tap
recognisers on the same pixels, one on the picture and one around the caption;
the inner one is gone.

One golden pair moved, `rich_reply_{dark,light}`: the composer in reply mode now
has the caret in it, so the field wears its focus border. That is the change,
drawn.

Covered by `apps/weft/test/a11y/keyboard_test.dart` (15 tests) and
`packages/weft_design/test/focus_test.dart` (6).

---

## Direction — resolved by task 6

Forty-two RTL findings, and one of them was load-bearing for the other
forty-one.

**CROSS-1 first, because nothing else was reachable without it.** The app
declared no locales and no localisation delegates, so `Directionality` resolved
to left-to-right for every locale a device could be set to. Switching a phone to
Arabic changed nothing in Weft, and no amount of `EdgeInsetsDirectional`
downstream would have changed that, because nothing was ever going to set the
direction. `flutter_localizations` is now a dependency,
`apps/weft/lib/app/localisation.dart` declares `en`, `ar` and `he` with the three
global delegates, and `main.dart` wires both. The first test in
`apps/weft/test/a11y/rtl_test.dart` is that finding: if it regresses, every other
test in the file quietly passes against a left-to-right app.

Two things came with it that were not asked for and are not optional.
`main` now awaits `initializeDateFormatting()`, and the app's `builder` — the
first place under `Localizations` — points `Intl.defaultLocale` at the resolved
locale, because every `DateFormat` in Weft is built without one. A `DateFormat`
for a locale whose symbols were never loaded *throws*, inside `build`, on every
bubble at once; `applyFormattingLocale` is guarded on `DateFormat.localeExists`
so a widget test can put the app into Arabic without its clock bringing the
screen down.

**String extraction is deferred, deliberately.** The phase asks that "`intl`
message lookup falls back cleanly for untranslated strings rather than showing
keys". Weft has no message catalogue at all — every user-facing string is a Dart
literal — so there are no keys to leak and the requirement is satisfied by there
being nothing to fall back from. Extracting the ~400 literals into ARB files is
a phase of its own. What the locales buy today is *direction* and *date
formatting*, which is what M10 is for; the honest half-state is an RTL layout
with English text, rather than an LTR layout pretending the locale does not
exist.

### What was built

- **`packages/weft_design/lib/src/bidi.dart`.** `textDirectionOf` resolves one
  string's base direction by the Unicode first-strong rule (UAX #9 P2/P3);
  `WeftDirectionality` applies it; `WeftLtr` pins a subtree the other way; and
  `WeftMirroredIcon` mirrors the two glyphs Material does not mirror for itself.
- **`apps/weft/lib/app/localisation.dart`.** `weftSupportedLocales`,
  `weftLocalizationsDelegates` and `applyFormattingLocale`.

### Findings closed

| ID | Resolution |
|---|---|
| CROSS-1 | `flutter_localizations` + `en`/`ar`/`he` + the three global delegates, wired in `main.dart`; `Intl.defaultLocale` follows the resolved locale |
| RTL-01 | The inbox column's `SafeArea` now skips the edge the rail is on, resolved from the direction rather than hard-coded to the physical left |
| RTL-02, 13, 14, 21, 23, 24, 25, 26, 27, 28, 30, 31 | All twelve `Alignment.center{Left,Right}` layout uses are `AlignmentDirectional.center{Start,End}` |
| RTL-03, 12, 16, 18, 19, 29, 33, 36 | All fifteen `EdgeInsets.fromLTRB` uses across twelve files are `EdgeInsetsDirectional.fromSTEB` |
| RTL-04 | The inbox list's padding is `EdgeInsetsDirectional`, for consistency rather than because it was wrong |
| RTL-05 | The empty-detail mark's gradient runs `AlignmentDirectional.topStart → bottomEnd`. So do the other five gradients in the app, which the register listed as cosmetic — a sheen that lights the wrong corner is what makes a mirrored screen look subtly assembled wrong |
| RTL-06 | Verified direction-neutral, unchanged |
| RTL-07 | The rail's `SafeArea` honours the physical edge it is actually on |
| RTL-08 | `AnimatedPositionedDirectional(start:)` — the accent bar slides in from the window's edge. `_RailEntry`'s `SlideTransition` was the same bug one layer up and now takes `textDirection` |
| RTL-09, 38, 39 | `PositionedDirectional(end:)` — the rail's unread badge, the avatar's network badge and its online dot |
| RTL-10, 15, 17, 41 | All four `Border(left:)` rules are `BorderDirectional(start:)` — the bubble hairline, the reply quote, the link preview and the blockquote |
| RTL-11 | The bubble tail is `BorderRadiusDirectional`, so it points at the side of the thread the message is on in either direction |
| RTL-20, 37 | Verified symmetric stretches, unchanged, as the register asked |
| RTL-22, 32 | `login_rounded` and `logout_rounded` are drawn through `WeftMirroredIcon` |
| RTL-34, 35 | `PositionedDirectional(end:)` — the call's local PiP window and the heads-up incoming banner |
| RTL-40 | The blockquote's indent is `EdgeInsetsDirectional.only(start:)` |
| RTL-42 | The code block is wrapped in `WeftLtr`, which pins both the text and the horizontal scroll view's axis |

### Bidirectional text

The phase's hardest line — "resolve each message's direction from its own
content, not the app locale" — is `textDirectionOf`, applied in three places:
the message body (`RichTextView`), the inbox row's title and preview
(`ChatTile`), and the composer, whose field follows what is being typed so
somebody answering a Hebrew message in an English UI gets a caret that starts on
the right.

Three decisions inside it are worth stating, because each has a plausible wrong
answer:

- **First-strong, not majority.** `Bidi.detectRtlDirectionality` counts RTL words
  against LTR ones and takes the majority, which is the right rule for guessing
  the language of a search result and the wrong one for a sentence somebody
  typed: under it a Hebrew message containing two English brand names flips to
  left-to-right, and flips back when the sender edits one out.
- **Null is a real answer.** "👍", "42" and ":)" have no direction to get wrong,
  and returning null lets them inherit the conversation's rather than pinning
  them to LTR inside an Arabic thread.
- **Astral characters are dropped before asking.** `Bidi`'s character classes are
  written over UTF-16 code units and its LTR range spans the surrogate block, so
  every emoji reads as strong Latin. Unfiltered, "👍" answers left-to-right and
  "👍 שלום" answers left-to-right too — wrong twice, and the second one is a
  Hebrew message rendered backwards.

The wrapper is as tight as it goes: only the paragraph flips. A message's side of
the thread, its tail, its ticks and the row it sits in all belong to the reader's
locale, which is what every other messenger does and what the reader expects.

### Four things later tasks must not get wrong

- **`import 'package:intl/intl.dart'` shadows `TextDirection`.** intl exports a
  class of that name, so in the seven files that imported it unqualified,
  `TextDirection.rtl` did not compile and `Directionality.of(context)` could not
  be compared to anything. All seven are now `show DateFormat`. A new file that
  needs both will hit this, and the error message does not say why.
- **Only two icons may be wrapped.** `reply`, `send`, `forward`,
  `chevron_right` and `open_in_new` all carry `matchTextDirection: true` in the
  SDK and mirror themselves; wrapping one would mirror it twice and point it the
  wrong way. The sweep that produced that list is in this document's
  [Verified correct](#verified-correct) section and was re-run against the
  installed SDK for this task.
- **`WeftMirroredIcon` is a `Transform`, not a rebuilt `IconData`.** Constructing
  an `IconData` with `matchTextDirection: true` would be tidier and cannot be
  used: a non-constant `IconData` anywhere in the tree is what makes
  `flutter build --tree-shake-icons` refuse the release build.
- **The tests sweep the source, and the sweep must keep reading everything.**
  `rtl_test.dart` fails on any new physical-edge API in `apps/weft/lib` or
  `packages/*/lib`, decoding bytes permissively rather than shelling out to
  `grep` — which is what makes it immune to the binary-file problem in the
  [Method](#method) note. It asserts a floor on the number of files it read, for
  the obvious reason. **Task 9's CI step should call this test rather than add a
  second grep**, or the two will disagree.

No pixels moved: all 20 golden pairs pass untouched, because every fix resolves
to the same geometry under LTR. The RTL goldens are task 8's, and they are the
first images that will show any of this.

Covered by `apps/weft/test/a11y/rtl_test.dart` (10 tests, including the two
source sweeps) and `packages/weft_design/test/bidi_test.dart` (11).

---

## Test suite — resolved by task 7

The four suites the phase asks for, and the fifteen touch-target findings the
tap-target guidelines were always going to be the arbiter of.

The rest of the a11y suite asserts particular sentences — that a bubble says who
spoke, that a merge says what it merged. Those tests are precise and blind: they
see only what somebody thought to write an expectation for. `meetsGuideline`
walks the *whole* semantics tree and reports every node that breaks a rule, so
it is the half that catches what nobody thought of — and it caught three things
this document did not have, listed at the end.

### What was built

- **`apps/weft/test/a11y/semantics_test.dart`** — 72 tests. Four guidelines
  (`labeledTapTargetGuideline`, `androidTapTargetGuideline`,
  `iOSTapTargetGuideline`, `textContrastGuideline`) over the six screens the
  phase names — inbox, chat, search, settings, bridges, merge — in **both**
  themes, plus a geometry-only sweep of the seven surfaces the touch-target
  register names that are not screens: the message actions sheet, the emoji
  picker, the appearance sheet, an incoming call, the minimised call bar, the
  composer of a merged chat, and a chat with an upload in flight and a voice
  message unplayed. Every one of those is reached by *driving* the app rather
  than by pumping the private widget behind it, because a sheet built by hand is
  a sheet with the test's own padding in it.
- **`apps/weft/test/a11y/live_region_test.dart`** — 8 tests. The two events the
  phase names, and the part a per-screen test cannot see: **how often**. A live
  region that re-announces on every rebuild is worse than none, because it talks
  over whatever the user is reading.
- **`apps/weft/test/a11y/keyboard_test.dart`** — extended from 18 tests to 27.
  Two additions: a sweep asserting that **every** control on the inbox, in a
  conversation and on search is reachable by Tab alone, taken from the semantics
  tree rather than from `WeftFocusable` so a Material button and one of Weft's
  own controls count the same way; and a table-driven group that fires **every**
  activator of **every** app-wide binding — Weft binds two keys to four of its
  five commands, and the old `press` helper only ever pressed the first.
- **`packages/weft_design/lib/src/tap_target.dart` — `WeftTapTarget`**, with
  `packages/weft_design/test/tap_target_test.dart` (7 tests). Material's own
  `_InputPadding` mechanism, which is private to `material/`: it grows the
  *interactive* box to a minimum, paints the child centred at its own size, and
  forwards a hit anywhere in the grown box to the child's centre.
- **`apps/weft/test/support/a11y_harness.dart`** — one way to put a screen on
  the glass, so a sweep that ran one screen at 1400×900 and another at the
  default 800×600 cannot report on the window instead of the widget.
  `controlNamesIn` and `focusedNameIn` joined `semantics_probe.dart`;
  `GrowingChatRepository` moved into `seeded_repository.dart` from
  `chat_semantics_test.dart`, where the live-region suite would have been the
  second copy.

### Why the tap target takes layout space

The tempting version of every fix below is to make the number a test reads go up
without making the control any easier to hit, and there are two ways to do it:
report a larger semantics rect than the box, or expand only the hit test. The
second is not available — a `RenderBox` never receives a pointer outside its own
bounds, because `RenderBox.hitTest` rejects it before the child is consulted —
and the first moves what a guideline measures without moving what a thumb has to
find. So `WeftTapTarget` takes the space, exactly as a Material `Checkbox` does:
18dp painted, 48dp occupied. Where the extra height was already there as a
margin, the call site gives the margin back.

### Findings closed

| ID | Resolution |
|---|---|
| CROSS-6 | Closed by task 2 and **verified here**: `contrast_test.dart` asserts every foreground/background pair over seven themes — light, dark and AMOLED, each with and without high contrast, plus a second seed — which is the phase's "light, dark and high-contrast" and two more. 194 assertions, unchanged |
| TAP-01 | **Verified correct, not changed.** `minimumSize: Size(0, 28)` shrinks what a `TextButton` *paints*; `ButtonStyleButton` wraps its `Semantics` around an `_InputPadding` that still reports 48dp, and the guideline passes it in both themes |
| TAP-02 | **Verified correct**, same mechanism as TAP-01 |
| TAP-03 | Fixed: `VisualDensity.compact` took 4dp off each axis of the padded target, leaving 40dp. Dropped — `iconSize: 18` already holds the glyph down, so the density was buying nothing the size did not |
| TAP-04 | Fixed: `WeftTapTarget` around the pill, which still paints at 28dp. The chip also carried a *second* node — the `InkWell`'s, labelled "👍\n2" at the old size — so the annotation now excludes its subtree and restates the tap |
| TAP-05 | Fixed: `WeftTapTarget`. The reaction bar's own top padding is gone, since the spare height inside the chips replaces it and is live rather than dead space |
| TAP-06 | Fixed: `WeftTapTarget`. Measured 44dp rather than the register's 31 — four short, on the only way back to the message being answered |
| TAP-07 | Fixed: `WeftTapTarget`. Measured 27dp **wide** by 50 tall, so the register's single number was hiding which axis was short — six identical neighbours where a miss sends the wrong reaction |
| TAP-08 | Fixed: `WeftTapTarget` on each cell, and the `Wrap`'s `spacing`/`runSpacing` dropped because the padding now provides it |
| TAP-09 | **Verified correct.** Swept through the composer of a merged chat, which is the only place the chip is drawn, and it passes both guidelines |
| TAP-10 | **Verified correct.** `FilterChip` defaults to `MaterialTapTargetSize.padded`; the 32dp in the register is the painted height, not the target |
| TAP-11 | Fixed: `VisualDensity.compact` dropped from the `SegmentedButton` style. Three adjacent choices where the neighbour of "Muted" is "Off", and a miss silences a network rather than quieting it |
| TAP-12 | Fixed: the swatch is 48dp rather than 44. It sits in a `Wrap` with room to spare, so the guideline is met by making the control the size it should be instead of padding a smaller one out to it |
| TAP-13 | Fixed: `WeftTapTarget` around the hang-up `InkResponse`. The one control in the app where a miss is expensive twice over, since the neighbouring target is the bar itself and a thumb that falls short opens the call screen |
| TAP-14 | **Verified correct.** The banner's `CallActionButton`s measure 48dp in the sweep; the register's 44 is the `size` argument, and the button pads around it |
| TAP-15 | Resolved by moving the affordance, not by growing it. A 10dp italic run inside a metadata line cannot reach 48dp without pushing every edited bubble 33dp taller, so **Edit history is now a row in the message actions sheet** — where the other eight operations on a message already are, and where a keyboard can reach it for the first time. The marker stays as an annotation that says where the versions went |

### Three findings this document did not have

- **The inbox's search placeholder was never painted.** `InputDecorator`
  defaults `isEmpty` to false, which tells the decorator the field it is
  dressing has content — so "Search all conversations" sat in the tree at zero
  opacity and the box drew a magnifier and nothing else. `textContrastGuideline`
  found it as a run of 16dp text at 1:1, which is what a colour histogram of a
  region with no glyphs in it reports. Every inbox golden shows the text now.
- **`WeftFocusable` emitted a duplicate, unlabelled node on every group.** The
  `GestureDetector` inside it declared the same long-press the annotation above
  it declares; two configurations that conflict cannot be folded together, so
  the framework gave the detector a node of its own — an unlabelled control the
  size of the message bubble. Invisible under `excludeSemantics: true` and
  therefore invisible on every control; visible on the one case that is a
  *group*, which is the bubble. Fixed with `excludeFromSemantics: true` on the
  detector plus `explicitChildNodes` on the annotation, which the group needed
  anyway — without it the bubble's links and mention pills fold into its label.
- **The inbox search field was a silent Tab stop.** `excludeSemantics: true`
  removes the phantom text field an `InputDecorator` announces, and it takes the
  `InkWell`'s *focus* semantics with it as well as its tap — so Tab stopped on a
  node with no name. It is a `WeftFocusable` now. This is task 5's lesson one
  layer along: a `Semantics` node is not a focus node, and excluding a subtree
  removes more than the label it was aimed at.

### Two things later tasks must not get wrong

- **`WeftTapTarget` goes *inside* the annotation, never outside it.** A node's
  rect is the size of the render object under the `Semantics`, so a tap target
  added above the label leaves the node exactly as small as it was — which is
  both what touch exploration lands in and what the guideline measures. The
  widget's own test pins this.
- **The guideline sweep is the arbiter, and it disagrees with the register in
  both directions.** Four of the fifteen entries pass untouched because Material
  pads a target the style only shrank the paint of; two of the ones that fail
  fail on an axis the register does not name. **Task 9 should quote the sweep
  rather than the register** when it writes the status column, and task 8 should
  expect the scale variants to move the same numbers again.

Covered by `apps/weft/test/a11y/semantics_test.dart` (72),
`apps/weft/test/a11y/live_region_test.dart` (8),
`apps/weft/test/a11y/keyboard_test.dart` (27, up from 18) and
`packages/weft_design/test/tap_target_test.dart` (7).

---

## Golden variants — resolved by task 8

`pumpWeft` takes a `WeftGoldenVariant` now — a locale, a text scale and a
high-contrast flag — and `weftAccessibilityVariants` is the four the phase
names: `ar`, 2.0×, 0.85× and high contrast. `apps/weft/test/goldens/a11y_golden_test.dart`
runs five scenes through all four in both themes: **40 new images**, named
`a11y_<scene>_<variant>_<theme>.png`. The pre-existing 20 pairs are byte-identical —
the scaler is applied at 1.0× as well, and the arithmetic is the identity there.

The harness also gained the app's own `localizationsDelegates` and
`supportedLocales`, and calls `applyFormattingLocale` with the variant's locale.
Both are load-bearing rather than tidiness: without the delegates `Directionality`
resolves left-to-right for every locale, so an image asked for in Arabic would be
an English-looking screen with an Arabic filename — a passing test of nothing.

### What the images show

| ID | Resolution |
|---|---|
| CROSS-7 | Closed. Four variants in the harness, five scenes, both themes |
| SCALE-2 | **Verified correct in the 2.0× image.** `InputDecorator` sizes its container to the *hint* when `isEmpty` is true, so the fake field grows and the placeholder wraps to two lines. The `SizedBox(height: 20)` is the notional input, and it is never the taller of the two |
| SCALE-3 | Verified correct — icon-only box, as the register said |
| SCALE-4 | **Fixed.** `height: 20` around an 11dp count: at 2.0× the digits are 22dp and the badge drew them with the tops and bottoms sliced off. Now `WeftUnreadBadge`, whose minimum is `textScaler.scale(extent)` on both axes |
| SCALE-5 | **Fixed**, same defect and now the same widget — `height: 18` around a 10dp count. Clamped to 1.3× on the rail alone: see below |
| SCALE-6 | Verified correct — glyph-sized, as the register said |
| SCALE-7 | **Verified correct in the 2.0× image, by a mechanism the register did not know about.** `AppBar` clamps its toolbar's text scaling, so `titleMedium` + `labelSmall` never exceed ~44dp inside the fixed 64. The clamp is the SDK's, applies to every Flutter app, and overriding it would make Weft's app bar the odd one out |
| SCALE-8 | **Not exercised.** The waveform's 60dp allowance needs a voice message, and none of the five scenes has one — see below |
| SCALE-9 | **Judged, not changed.** At 2.0× a 520dp bubble is a narrow column of large text, which is what every messenger does with a width cap; the alternative is a full-width line at 32dp, which is worse to read. The 600dp chat window makes the cap non-binding in these images anyway |
| SCALE-10 | Verified correct — decoration, as the register said |
| SCALE-11 | **Not exercised.** The verification screen is not one of the five scenes |
| SCALE-12 | Verified correct — icon-only, as the register said |
| SCALE-13 | Closed by task 4 |
| SCALE-14 | Verified correct — ellipsised, as the register said |
| SCALE-15 | Verified correct — a video surface, as the register said |
| SCALE-16 | **Not exercised.** A list marker needs a formatted body with a list in it, and the mixed-direction thread is plain text |

**SCALE-8, SCALE-11 and SCALE-16 are open**, and what blocks them is scope
rather than difficulty: the phase names five scenes — inbox, mixed-direction
chat, composer in reply mode, search and settings — and those three findings
live on a voice bubble, the verification screen and a formatted body, none of
which appears in any of them. None is a golden question. Each is "does this box
still hold its text at 2.0×", which
`packages/weft_design/test/text_scale_test.dart` already answers for SCALE-1, 4
and 5 by measuring rects — three assertions in that shape close them, and task 9
should write them there rather than add three more scenes.

### Two findings this document did not have

- **A search result took the locale's direction rather than its own.** Visible
  in `a11y_search_rtl_light.png` as `?did the roof people ever send the quote` —
  the bidi algorithm correctly laying out an English sentence in a right-to-left
  paragraph, given a paragraph it should never have been in. A result snippet is
  message content, so it resolves its own direction the way a bubble and a chat
  tile already do; the attribution line under it does too, since a Hebrew sender
  in an English UI is the same bug mirrored. Pinned in `rtl_test.dart` rather
  than only by the image, because a golden diff is an unreadable way to report a
  misplaced question mark.
- **Fixing SCALE-5 made the rail badge swallow the icon it counts for.** The
  first fix let the pill grow with the text; at 2.0× that is 36dp of badge over
  a 36dp brand glyph in a 76dp rail, neither of which scales — a clipped number
  traded for an unidentifiable network. The rail's badge is clamped to 1.3×,
  which is the only clamp in the app and is stated at the call site. The chat
  row's badge has a column of its own and is deliberately unclamped.

### Three things later tasks must not get wrong

- **A `MediaQuery` above `MaterialApp` is not where a text scaler goes.**
  `MediaQuery.fromView` rebuilds the data from the view, so a scaler set above
  the app reaches the tree only through the platform-data back door and a route
  pushed later does not see it at all. `pumpWeft` sets it in the app's
  `builder`, which is where the app itself reads these.
- **`Intl.defaultLocale` is global and the harness restores it.** A suite that
  left it at `ar` would hand the *next* file's goldens Arabic-Indic timestamps,
  and the failure would land in whichever test happened to run next. Anything
  that adds a locale-varying golden must keep the teardown.
- **The right-to-left images have no right-to-left glyphs, on purpose.** The
  SDK's Roboto covers zero of the 112 Hebrew codepoints and zero of the 256
  Arabic ones, so every RTL word draws as a placeholder box — the same trade
  `rich_content_golden_test.dart` makes for emoji, and for the same reason:
  reaching for a host font would make the images depend on which machine took
  them. Bidi resolution happens before shaping, so direction is still legible in
  the boxes' *arrangement*, which is the whole claim. Reading the words is
  **task 10's** device pass, not something to "fix" by vendoring a font.

### The one thing an RTL image shows that is not being fixed

Weft's untranslated English chrome renders with displaced punctuation under an
RTL locale — `.Every network, one thread`, `results 3`, `.Keyword search only…`.
This is the bidi algorithm being correct: an English sentence in a right-to-left
paragraph puts its trailing full stop on the left. Pinning those strings to LTR
would un-mirror their alignment and would be wrong the day they are translated,
so the fix is the string extraction task 6 deferred, and this is one more reason
to do it. Recorded here so task 9 does not read the images as a layout defect.

Covered by `apps/weft/test/goldens/a11y_golden_test.dart` (20 tests, 40 images),
`packages/weft_design/test/text_scale_test.dart` (13 new) and
`apps/weft/test/a11y/rtl_test.dart` (1 new).

---

## Closed — task 9

The whole tree run, the last three findings measured, and the audit's status
column filled in. **Every one of the 234 findings is now fixed, verified
correct, or deferred with a stated blocker**; the four deferrals are listed at
the end of this section, and none of them is an accessibility defect left
standing.

### The run

| Suite | Result |
|---|---|
| `dart test` × 12 pure packages | **1026 pass** |
| `flutter test` — `weft_design` | **259 pass** |
| `flutter test` — `weft_matrix` | **278 pass** |
| `flutter test` — `weft_store` | **44 pass** |
| `flutter test` — `apps/weft` | **907 pass** (889 before this task) |
| `dart analyze` from the root | **No issues found** |
| `dart format --set-exit-if-changed .` | **3 files changed** — see below |
| `apps/weft/test/goldens` | **42 pass**, all 60 images byte-identical |

**2514 tests**, and `analyze` was clean before anything here was touched.

`dart format` was not. Three files task 8 added or edited —
`test/goldens/a11y_golden_test.dart`, `test/support/golden_harness.dart` and
`packages/weft_design/test/text_scale_test.dart` — were unformatted, which is a
red `analyze` job on the next push and nothing to do with accessibility. They
are formatted. Worth stating because the phase has run eight tasks without CI
seeing any of them: **`dart format` is a CI gate here and the local loop is
`flutter test`, so drift accumulates silently between pushes.**

### The last three text-scale findings

Task 8 left SCALE-8, SCALE-11 and SCALE-16 open and named the shape that closes
them: rect assertions rather than three more golden scenes. They are in
`apps/weft/test/a11y/text_scale_test.dart` — **18 tests**, four scales
(0.85×, 1.0×, 1.3×, 2.0×) over each.

Not in `packages/weft_design/test/text_scale_test.dart`, where task 8 pointed:
all three boxes live in `apps/weft/lib/features/`, and `weft_design` cannot see
them. Same file name, same shape, the other side of the dependency edge.

| ID | Resolution |
|---|---|
| SCALE-8 | **Verified correct, and the register's diagnosis was wrong.** The waveform is `Flexible` and the duration label is not, so the `Row` gives the label its full natural width *first* and the bars absorb what is left — the `maxWidth - 60` is slack subtracted from a width the label had already been taken out of. Measured at 2.0× in a 360dp window with the widest string `formatMediaDuration` produces (`70:10`, 58dp): nothing truncates, nothing overflows. Pinned rather than fixed |
| SCALE-11 | **Fixed.** The 74dp cell gave its caption 66dp for two lines; at 2.0× that is 22dp type, and the longest names the SAS table holds — `Strawberry`, `Light Bulb`, `Headphones`, all ten characters — ellipsised. The user is being asked to compare *those words* against another screen, so `Headphon…` is the verification step failing, not a cosmetic clip. The cell now scales with the text, clamped at 1.6× |
| SCALE-16 | **Fixed, and it was a real clip at every scale above 1.4×.** The ordered marker's gutter was a fixed 26dp: `10.` needs 40dp at 2.0×, so a list wrapped its own numbers onto a second line — `10` over `.` — from the tenth item down. The gutter is `textScaler.scale(26 | 16)` now, unclamped, since there is nothing behind it to cover |

Both fixes were checked by reverting them: without the scaled gutter,
`10.` lays out 80dp tall where one line is 40; without the scaled cell,
`Headphones` reports `didExceedMaxLines`. A test that passes against the bug it
names is the failure mode worth spending two runs to rule out.

**`SasEmojiCell` is public now**, extracted from `_EmojiCompare`. Not tidiness:
a `KeyVerification` needs an `Encryption` and a live client, so the verification
screen cannot be pumped in a widget test at all, and SCALE-11 is a question
about that one box. `pumpScreen` in `test/support/a11y_harness.dart` gained a
`textScale` seam for the same reason — the voice bubble is private inside
`chat_view.dart` and is only reachable by pumping the screen that owns it.

Two things a later reader should not undo:

- **The measurement is worthless without real fonts.** `flutter_test`
  substitutes a fixed-width placeholder face, under which the marker `8.` needs
  28.5dp where Roboto needs 11 — so an unfixed suite reports a clip no device
  has and stays quiet about the one it does. `setUpAll(loadGoldenFonts)`, in
  every file that measures a width.
- **`StubChatRepository` must be given `uploads: const []`, not null.**
  `DemoChatRepository` otherwise drives its own upload simulation on a
  zero-duration tick and `pumpAndSettle` never returns — a two-minute timeout
  whose message says nothing about uploads.

### CI

Three named steps in a new `a11y` job, plus one real hole closed in an old one.

**`packages/weft_design` was in no CI job at all.** Not in `unit` — it is a
Flutter package and cannot run under `dart test` — and not in `widget`, whose
list was written when the package had no tests. Its whole suite has been unrun
on every push of this phase, `contrast_test.dart` included: 194 assertions over
seven themes, and the only thing in the repository that would notice a token
dropping below WCAG AA. It is in the `widget` job's Flutter-package loop now,
beside `weft_matrix` and `weft_store`.

The new `a11y` job runs `apps/weft/test/a11y`, `apps/weft/test/goldens` and
`packages/weft_design`, and uploads golden diffs on failure. It is a subset of
what `widget` already covers, deliberately: the overlap costs under a minute and
buys a red check that reads *Accessibility & RTL* without anyone opening a log.

**No grep step, on purpose.** Task 6 asked for this and it is worth restating:
`rtl_test.dart` sweeps the source for physical-edge layout APIs by reading the
tree's bytes, and it is a test rather than a shell step because both BSD and GNU
`grep` classify two files in this workspace as binary and drop their matches
*silently* — see the [Method](#method) note, which is how the first pass of this
audit missed `rich_text_view.dart` entirely. A grep step in CI would be a second
compliance check that disagrees with the first and is wrong more often.

### Deferred, with what blocks each

Four, and the reason matters more than the count.

1. **String extraction — ~400 Dart literals into ARB catalogues.** Blocked by
   scope: it is a phase of its own, not a task. It is *not* blocking the phase's
   stated criterion — "`intl` message lookup falls back cleanly for untranslated
   strings rather than showing keys" — because Weft has no catalogue, so there
   are no keys to leak and nothing to fall back from. What it does block is the
   displaced punctuation in the RTL goldens (`.Every network, one thread`),
   which is the bidi algorithm being correct about English text in an Arabic
   paragraph. Pinning those strings to LTR would be wrong the day they are
   translated. **First** thing M11 should pick up.
2. **A11Y-08's visual half — read and delivered are the same double tick in two
   colours.** Closed for a screen reader in task 3 (named in the label and in
   the tooltip) and open for a sighted user with a colour vision deficiency.
   Blocked on design, not on code: telling them apart means changing the mark,
   and which mark is not this phase's call. The one place in the app where
   colour is still the sole signal — see
   [Verified correct](#verified-correct) item 7 for the four places that got it
   right.
3. **SCALE-9 — the bubble's 520dp `maxWidth`.** Judged in task 8 and left: at
   2.0× the cap makes a narrow column of large text, which is what every
   messenger does, and the alternative is a full-width 32dp line that is worse
   to read. Not blocked — decided.
4. **Real assistive technology.** VoiceOver, TalkBack and a device in an RTL
   locale are **task 10**, and this document gets its `Verified with` section
   there. Everything above is `SemanticsTester`, `meetsGuideline` and rects:
   nothing in this phase has yet been heard out loud, and a label that reads
   correctly in a tree can still be announced in the wrong order by a real
   screen reader.

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

**All closed by task 7** — see
[Findings closed](#findings-closed-2) there for the per-entry resolutions. Read
the sizes above as *approximate and sometimes of the wrong thing*: they were
measured off the source, and the tap-target guidelines that later swept these
screens disagreed with five of them. TAP-01, TAP-02, TAP-09, TAP-10 and TAP-14
measure the painted control while Material pads the target around it, and pass
untouched; TAP-06 was 44dp rather than 31; TAP-07 was short on width, not
height.

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

**All sixteen closed** — twelve by the 2.0× goldens (task 8, see
[What the images show](#what-the-images-show)), SCALE-13 by task 4, and
SCALE-8, SCALE-11 and SCALE-16 by rect assertions in task 9 (see
[The last three text-scale findings](#the-last-three-text-scale-findings)).
Read this register the way the touch-target one above is read: it was written
off the source and it guessed wrong about which boxes actually clip. Seven
entries were already correct; SCALE-2 and SCALE-7 pass by SDK mechanisms it did
not know about; SCALE-8's diagnosis was wrong in the other direction — the box
it names does not clip, and the arithmetic it points at is measuring something
else. **Two of the sixteen were real clipping and both were the same defect
written twice** (SCALE-4 and SCALE-5), plus SCALE-11 and SCALE-16 found later
by measuring rather than by reading.

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
| 9 — run everything, close the audit | SCALE-8, SCALE-11, SCALE-16, and this document's status column |
| 10 — real assistive technology | the `Verified with` section, appended then |

Totals: **140 semantics findings**, **42 RTL findings**, **16 text-scale
findings**, **15 touch-target findings**, **8 contrast findings**, **5 keyboard
findings**, **8 cross-cutting findings** — 234 in all.

## Status

**Closed. All 234 findings are fixed, verified correct, or deferred with a
stated blocker**, and the four deferrals are enumerated under
[Deferred, with what blocks each](#deferred-with-what-blocks-each). None of them
is an accessibility defect left standing: one is a translation phase, one is a
design decision about a glyph, one is a judgement already made, and one is task
10's device pass. 2514 tests pass across the workspace, `dart analyze` is clean,
and the suites that prove all of this now run in CI — including
`packages/weft_design`, which ran in no job at all until task 9.

What was closed, by task: the token layer (task 2 — see
[Resolved by task 2](#resolved-by-task-2)), the inbox, chat and composer
semantics (task 3 — see
[Semantics — resolved by task 3](#semantics--resolved-by-task-3)), every
remaining screen (task 4 — see
[Semantics — resolved by task 4](#semantics--resolved-by-task-4)), the
keyboard model (task 5 — see
[Keyboard — resolved by task 5](#keyboard--resolved-by-task-5)),
direction-agnostic layout (task 6 — see
[Direction — resolved by task 6](#direction--resolved-by-task-6)), the test
suite and touch targets (task 7 — see
[Test suite — resolved by task 7](#test-suite--resolved-by-task-7)), the golden
variants (task 8 — see
[Golden variants — resolved by task 8](#golden-variants--resolved-by-task-8))
and the last three text-scale findings, the full-tree run and the CI steps
(task 9 — see [Closed — task 9](#closed--task-9)).

**All 140 semantics findings are now closed**, along with CROSS-2 and CROSS-8.
One of them, **A11Y-08**, is closed for a screen reader and explicitly deferred
to design for its visual half; two more, **A11Y-97** and **A11Y-103**, are
closed as already-mitigated and were left unchanged, since the state they encode
in colour is stated in words beside the glyph.

**All five keyboard findings and CROSS-3 are now closed**, along with A11Y-127.
One of them, **KEY-03**, was already closed by task 2 and is recorded as
verified rather than re-fixed.

**All 42 RTL findings and CROSS-1 are now closed.** Four of them — RTL-06, 20,
37 and the second half of the register's gradient row — were verified correct
and left unchanged rather than re-fixed, which is what the
[Verified correct](#verified-correct) section is for. One requirement inside
task 6 is explicitly **deferred**: extracting Weft's ~400 string literals into
ARB message catalogues. What blocks it is nothing technical — it is a phase of
its own, and with no catalogue there are no keys to leak, so the phase's
"falls back cleanly rather than showing keys" criterion is met today. The
locales buy direction and date formatting, which is what M10 needs.

**All 15 touch-target findings are now closed** by the test suite (task 7 — see
[Test suite — resolved by task 7](#test-suite--resolved-by-task-7)), along with
CROSS-6, which task 2 fixed and task 7 verified. Four of the fifteen — TAP-01,
TAP-02, TAP-09, TAP-10 and TAP-14 — pass the guidelines untouched and are
recorded as verified rather than re-fixed: in each case the register measured
what the control *paints* and Material was already padding the target around it.
One, **TAP-15**, is resolved by moving the affordance rather than growing it,
since a 10dp run inside a metadata line cannot reach 48dp without pushing every
edited bubble apart; the edit history is a row in the message actions sheet now.

**CROSS-7 and twelve of the fifteen remaining text-scale findings are now
closed** by the golden variants (task 8 — see
[Golden variants — resolved by task 8](#golden-variants--resolved-by-task-8)).
Two were real clipping — SCALE-4 and SCALE-5, the same defect twice, now one
`WeftUnreadBadge`; SCALE-9 was judged and deliberately left; the other nine pass
in the 2.0× images, two of them (SCALE-2, SCALE-7) by a mechanism the register
did not know about and had guessed wrong.

**The last three — SCALE-8, SCALE-11 and SCALE-16 — are closed by task 9**, as
rect assertions rather than as three more golden scenes (see
[The last three text-scale findings](#the-last-three-text-scale-findings)).
Two were real: the SAS emoji cell ellipsised the names the user is being asked
to compare, and the list marker's gutter wrapped `10.` onto a second line inside
its own box. SCALE-8 was not — the waveform's `Flexible` already reserves the
duration's full width, and the register's `maxWidth - 60` diagnosis pointed at
arithmetic that measures something else. It is pinned rather than fixed.

The work list's task 3 row originally read "A11Y-01…31, 34…47", which orphaned
A11Y-32 and A11Y-33 — the link preview card, a chat surface with no other task
claiming it. They were fixed there and the row corrected. CROSS-8 moved to task
3 too, since it asked for one app-wide answer and task 3 is where the first call
site needed it; task 4 closed its remaining eight call sites.

## Verified with

Everything above this section was established by reading code and by running
tests. This section is the phase's last task and a different kind of evidence:
the app built, installed and driven on a device, with a real screen reader
running, and the answers written down whether or not they agree with the tests.

They did not entirely agree. **Five defects were found here that the whole
suite — 2 500 tests, four accessibility guidelines swept over six screens in
two themes, sixty golden images — could not see**, and one of them made a
conversation unusable by touch exploration. All five are fixed, with the fixes
re-verified on the same device; each has a regression test that fails against
the bug it names. The reason the suite was blind to them is worth as much as
the defects: see [Why the suite could not see
these](#why-the-suite-could-not-see-these).

### What was tested, with what

| | |
| --- | --- |
| **Device** | Android emulator `Medium_Phone_API_36.1` — Android 16 (API 36), 1080×2400 at 420 dpi (2.625×), Google APIs image, unrooted |
| **Build** | `flutter build apk --debug --dart-define=WEFT_DEMO=true`, installed with `adb install -r -t` |
| **Screen reader** | TalkBack (Android Accessibility Suite `com.google.android.marvin.talkback`), enabled with `settings put secure enabled_accessibility_services …` and confirmed bound in `dumpsys accessibility` |
| **What was read** | The exported `AccessibilityNodeInfo` tree — `adb shell uiautomator dump` — which is the tree TalkBack composes its speech from, plus TalkBack's own focus rectangle located in screenshots by its colour (`#64C040`/`#6BC840`) |
| **Locales** | `cmd locale set-app-locales com.bostrot.weft --locales ar`, then `he`, then cleared |
| **Screens reached** | Inbox, a merged three-network conversation, a single-network conversation, search with a query and its filters, the merge screen |
| **macOS** | Built and launched (`flutter build macos --debug --dart-define=WEFT_DEMO=true`); **VoiceOver not run** — see [macOS, not verified](#macos-not-verified) |

Three limits of the method, stated because they bound what the passes below are
worth:

- **TalkBack's speech was not captured as text.** It is not in logcat at the
  default level, and raising TalkBack's own log level needs its private
  preferences, which an unrooted Play-image emulator will not hand over. What
  is quoted below is the node tree TalkBack reads, not a recording of it
  speaking.
- **Linear navigation could not be driven.** Injected events — `input swipe`,
  `input keycombination 57 22` (Alt+→) — bypass TalkBack's gesture and key
  interception; eighteen consecutive swipes left the focus rectangle exactly
  where it started. So **reading order below is the exported tree's order**,
  which is what TalkBack's linear navigation follows, rather than a walk
  observed gesture by gesture. Touch exploration was likewise unavailable:
  injected taps activate controls directly instead of focusing them.
- **The emulator needed 6 GB.** At the AVD's stock memory, enabling TalkBack
  put SystemUI into a repeating ANR within minutes and left a phantom dialog
  window that `uiautomator` kept returning instead of the app. `-memory 6144
  -cores 4` on a cold boot ended it. Anyone repeating this should start there
  rather than spend an hour, as this did, concluding the app was at fault.

### What failed, and is now fixed

Five findings, in the order they surfaced. Each one was reproduced as a failing
test before being fixed, and each fix was re-verified on the device.

**DEV-1 — the chat view announced the whole conversation as an edit box.**
The exported tree had a single `android.widget.EditText` at `[0,231][1080,2400]`
— the entire body below the app bar — with hint `Message via Signal`, holding
the scroll view, every bubble and the send and attach buttons as its children.
Touch exploration anywhere in the thread landed on "Message via Signal, edit
box".

The cause is one line, repeated at seven call sites:
`Semantics(label: …, textField: true, child: TextField(…))`. A `Semantics` with
the default `container: false` does not make a node — it merges its label and
its flags into the nearest *enclosing* node, and for a composer at the bottom of
a screen that is the screen. `WeftLabelledField` in `weft_design` is the fix
(`container: true`) and all seven fields use it: the composer, the search field,
the share sheet's chat filter, the bridge dialog's URL field and login's three.
Only the composer was doing real damage — in a dialog or an app bar the nearest
ancestor is about the size of the field anyway — but the shape was identical
everywhere and the difference was luck. Re-verified: the composer's nodes are
now `[326,2180][902,2306]` and nothing else on the screen is a text field.

**DEV-2 — the send-network chip put its name and its tap on the conversation.**
Visible only once DEV-1 was fixed: the same body-sized node came back as
`View 'Send via Signal'`, `clickable`, still `[0,231][1080,2400]`. Everything
the chip paints is deliberately silent — a `NetworkGlyph` with
`semanticsLabel: ''` because the tooltip already names the network, and a bare
chevron — so the `Tooltip` and `InkWell` that `PopupMenuButton` wraps around it
had no node of their own to annotate and merged upwards for the same reason
DEV-1 did. A `MergeSemantics` around the chip gives them a boundary the size of
the chip. Re-verified: `[32,2180][179,2306]`, which is 56×48 dp.

**DEV-3 — the same chip was 56×36 dp, under the 48 dp minimum.** Found by the
existing guideline sweep the moment DEV-2 was fixed, and unfindable before it:
a control whose tap action lives on a screen-sized node passes a tap-target
check trivially. `WeftTapTarget` now, which is the mechanism task 7 built for
TAP-01…15. **Eighteen golden images moved** and the diff in each is confined to
a 56×42 box at the chip.

**DEV-4 — a merged bubble said its network three times.** The tree read
`'Anna Maven, on WhatsApp'` → `'WhatsApp'` → `'WhatsApp'` → the body → the time,
for every bubble in a merged thread: the group node names the leg, and then the
caption row above the text contributes both its glyph's label and its own text.
`ExcludeSemantics` around that row — it is how a *sighted* reader learns the
leg, and a reader who has just been told does not need it twice more. The chat's
node count fell from 78 to 61.

**DEV-5 — search's network filters said it twice**, `'WhatsApp\nWhatsApp'`: a
`FilterChip` whose label is the network's name with a `NetworkGlyph` avatar that
says it again. `semanticsLabel: ''`, which is what `NetworkGlyph`'s own
documentation asks for and what two other call sites already did. The same
reading of the code found two more — the bridges screen's detected-bridge tile
and its bridge card, both with the network's name in the text beside the glyph.
The glyph is left speaking where it is the only thing that names the network:
the reply chip, and the merge screen's handle rows, where the text beside it is
a person's name.

### What passed

Read off the same trees, on the device, in the same session:

- **A chat tile is one node and one sentence.** `Anna Maven, merged across 3
  networks: WhatsApp, Signal, Telegram, pinned, Can you send the clinical trial
  summary?, 16:40, 3 unread` — and `Sofia Martinez, Telegram, Read, Let me know
  when it's done, 15:12`, `Dr. James Anderson, Instagram, muted, …`. Eleven
  rows, eleven nodes, every one of them carrying both `clickable` and
  `long-clickable`.
- **The rail states counts and selection.** `WhatsApp, 4 unread`,
  `Matrix, 5 unread`, `Instagram` with no count, and
  `All conversations, 27 unread` carrying `selected`.
- **Disabled controls say why they are disabled**, which is the half of a
  disabled control that is usually missing: `Search in conversation — not
  available yet`, and `WhatsApp, Signal and Telegram can't carry calls — Weft
  calls over Matrix.`
- **A bubble names its sender and its leg, once**, with the delivery state in
  the same clause as the time: `Sent 15:51, Read` on own messages, `Sent 15:14`
  on the peer's. On a **single-network** chat the same bubbles are `Konrad
  Majewski` and `You` with no leg named — the distinction the audit's *Verified
  correct* section asks for, holding on a device.
- **The composer states its mode**: hint `Message via Signal` on the merged
  chat, and it is on the composer's own node.
- **Day dividers are headings**: `Messages from Aug 15`.
- **TalkBack's focus rectangle paints**, and moves to the newly-opened screen's
  first control on a navigation — observed on the back button of the merge
  screen and of a conversation.
- The emoji in a tile's preview reach the label intact (`🎙 Hey, are we still on
  for Thursday?`), which is [[Rich-Content]]'s side of the inbox row.

### RTL, on the device

Set with `cmd locale set-app-locales`, per app, since an unrooted emulator will
not take a system locale. Checked in **Arabic** and **Hebrew**, against
`a11y_inbox_rtl_*` and `a11y_chat_mixed_rtl_*`.

**The device agrees with the goldens, and shows one thing they cannot.** The
goldens render every Arabic and Hebrew word as a placeholder box, because the
SDK's test font has no glyphs for either — task 8 recorded that as deliberate.
On the device the dates are real words: `الجمعة`, `الخميس`, `الأربعاء` in
Arabic, `יום ו׳`, `יום ה׳`, `יום ד׳` in Hebrew. That is `initializeDateFormatting`
and `Intl.defaultLocale` working end to end on a real platform, which is the one
part of task 6's locale work no test in the repository actually proves.

The layout: rail on the right, avatars on the right, timestamps and unread
badges on the left, the merged chip and its glyph row mirrored, the search
field's magnifier on the right. In a conversation, own bubbles sit at the end
(left) and the peer's at the start (right), the tails and ticks follow them, the
back arrow points right and the send glyph points left — both mirrored by the
SDK, as task 6's *Verified correct* note predicted. Timestamps stay
left-to-right inside a right-to-left row.

**The known English-chrome effect is there and is not a layout defect.** The app
bar subtitle reads `…Merged · WhatsApp, S` with the ellipsis at the left of the
run. That is the bidi algorithm laying out an English sentence correctly inside a
right-to-left paragraph, exactly as task 8 described for `.Every network, one
thread`. What fixes it is the deferred string extraction, and nothing else
should be done about it.

### Still open

**DEV-6 — the rail is split by the header in reading order.** The exported order
on the inbox is: `All conversations, 27 unread`, then `Conversations`, then
`Appearance` and `More`, then the *other* seven rail items, then the search
field, then the list. A reader meets the first rail entry, leaves the rail for
the title and the two app-bar buttons, and comes back to it.

This is not the keyboard order — task 5's `OrderedTraversalPolicy` governs where
Tab goes, and a semantics traversal order is a different ordering, set with
`SemanticsSortKey`, that nothing in Weft sets. So the two are consistent by
accident on every screen where they agree, and disagree here. **Left open
deliberately**: the fix is `Semantics(sortKey: OrdinalSortKey(…))` on the rail,
the header, the search field and the list, and it wants a device pass of its own
rather than a change made at the end of a phase and verified by a widget test
that, as DEV-1 shows, would not necessarily see the difference. Recorded with
the shape of the fix so it starts from here.

**Surfaces not reached on the device.** The device pass covered the inbox, two
conversations, search and merge. It did **not** reach the attachment surfaces
([[Attachment-Pipeline]]), the media viewer, the call screens, the settings
screens or the share sheet — all of which have semantics closed against tests
in tasks 3 and 4, none of which has now been read by a screen reader on a
device. Nothing here suggests they are wrong; the point is that DEV-1 through
DEV-5 were all found in the first two screens looked at, so the rate is not
zero and the remaining surfaces should get the same treatment.

### macOS, not verified

The macOS app builds and runs — `flutter build macos --debug
--dart-define=WEFT_DEMO=true`, launched, process alive, quit cleanly. **VoiceOver
was not run**, and the reason is a permission rather than a defect:

- `osascript` cannot reach `System Events`: *"Keine Berechtigung zum Senden von
  Apple-Events an System Events. (-1743)"* — the Automation consent is a dialog,
  and this session has no one to answer it.
- `screencapture` returns *"could not create image from display"* — Screen
  Recording consent, same problem.
- Starting VoiceOver without those two permissions would have been a one-way
  door: `open /System/Library/CoreServices/VoiceOver.app` turns it on, and
  turning it off again, or driving it with VO+arrow keys, needs exactly the key
  injection that is refused. Leaving somebody's Mac speaking with no way to stop
  it is a worse outcome than an unfinished check, so it was not attempted.

For whoever has a keyboard in front of them, it is about ten minutes:
`flutter run -d macos --dart-define=WEFT_DEMO=true`, Cmd+F5, then VO+→ through
the inbox, into a conversation and into the composer. **DEV-1 and DEV-2 are the
two to look for first** — both are platform-independent, both were invisible to
every test, and VoiceOver on the Mac would have reported them the same way
TalkBack did.

### Why the suite could not see these

Worth stating plainly, because the same blindness will hide the next one.

The natural way to assert a field's name is
`tester.getSemantics(find.byType(TextField))`. That walks **up** from the render
object to the first semantics node it meets — so when an annotation has leaked
into an ancestor, the leaked node *is* what it returns, with the right label on
it. The assertion passes on the strength of the bug. Every check written for
this section starts at the root, walks down, and asserts about the node's
**rect**, which is the part that was wrong.

Three tests now cover the shape rather than the instances:

- `apps/weft/test/a11y/semantics_test.dart` — *no control is the size of its
  screen*, over the same six screens as the guideline sweep plus a merged chat
  (the send chip only exists on one), using `oversizedControlsIn` in
  `test/support/semantics_probe.dart`. It fails at `"Send via Telegram" is
  1400×836` and `"Message via Signal" is 1400×836` against the old code.
- `packages/weft_design/test/labelled_field_test.dart` — `WeftLabelledField` is
  named, is no bigger than its field, keeps its name after typing, and does not
  swallow a button in the decoration. The last one is why the fix is
  `container: true` and not `MergeSemantics`: merging folds the clear-search and
  change-server buttons into the field.
- `apps/weft/test/chat_semantics_test.dart` — a merged bubble's labels contain
  `Anna Maven, on Telegram` and do **not** contain a bare `Telegram`.

### The run

`dart analyze` from the root: *No issues found*. **2 525 tests pass** — 1 026 in
the twelve pure packages, 278 in `weft_matrix`, 44 in `weft_store`, 262 in
`weft_design` (+3) and 915 in `apps/weft` (+8), against task 9's 2 514. Sixty
golden images, eighteen of them regenerated for DEV-3 and inspected; the rest
byte-identical.
