---
type: decision
title: 'ADR-003: the macOS surface'
created: 2026-08-26
status: accepted
tags:
  - macos
  - design
  - desktop
  - theme
related:
  - '[[Design-System]]'
  - '[[Inbox]]'
---

# ADR-003: the macOS surface

**Status:** accepted · **Date:** 2026-08-26

## Context

Braid's macOS build was the phone app in a window. A 76pt icon rail, a 28pt
headline that scrolled away, a row of pill filter chips, 74pt conversation rows
with 46pt avatars, a purple floating action button in the bottom-right corner,
bottom sheets sliding up from the dock, message bubbles run to the full width of
a 27" display, and a stock title bar with none of it underneath. Everything on
that list is a correct answer to *not having room*, and none of those answers
is available to be right on a machine that has a pointer, a keyboard, a menu
bar and a window the user can resize.

## Decision

**The surface is one decision, made once, carried in the theme.**

`WeftSurface` has two values — `touch` and `mac` — and `WeftTheme.build` takes
it. Everything a platform changes that *can* be a theme value is one: the type
scale (13/11 rather than Material's 14/16), the control density, the corner
radii, the absence of a ripple, the scrollbar, the tooltip delay, the dialog
shape. Widgets that need more than metrics read `context.isMac`.

The alternative — `Platform.isMacOS` at each call site — was rejected for the
reason every other cross-cutting fact in this codebase is read from the theme:
a widget that asks the platform directly cannot be golden-tested in the other
case, and half of them forget to ask at all.

**Two shells, not one shell with thirty conditions.** `InboxShell` dispatches
to `MacInboxShell` on the desktop. They share the providers, the repository and
every component; they share no chrome. A network rail is not a narrow sidebar
and a header that scrolls away is not a toolbar, so expressing one as the other
would describe both badly.

**Windows and Linux stay on the touch surface,** deliberately. Everything the
desktop layout is built from here is macOS — system type sizes, vibrancy,
traffic-light clearance, a sheet from the title bar. Giving Windows a Mac window
fits worse than giving it the phone's, which at least does not claim to be
native.

## What that produced

| Phone | Mac |
|---|---|
| 76pt icon rail | 220pt source list: smart folders, networks, labels, destinations |
| Headline + search pill + chip rows, all scrolling | Unified toolbar per pane, content scrolling under it |
| Floating action button | Compose in the toolbar |
| Bottom sheets | Popovers at their control, or a sheet from the title bar |
| 46pt avatars, 74pt rows | 32pt avatars, ~50pt rows, accent-filled selection |
| Full-width bubbles | 760pt reading column |
| No menus | File / Edit / View / Conversation / Window / Help |
| Stock title bar | Full-size content, vibrancy, traffic lights over the sidebar |

## Consequences

**The window is transparent.** `MainFlutterWindow` adds an `NSVisualEffectView`
with the `.sidebar` material and clears the Flutter view's background, which is
the only way to get the real material — the compositor blurring the desktop.
A `BackdropFilter` can only blur what Flutter itself drew, so a sidebar built
that way is glass over a wall.

The cost is that every pane must paint itself, and the sidebar must *not*. Its
tint is heavy (0.90 in dark, 0.86 in light) so that a build without the native
chrome — a golden, a future platform — degrades to a slightly-lifted dark
sidebar rather than a white one.

**Glass has an opaque fallback** under `MediaQuery.highContrast`. Flutter
surfaces no "reduce transparency" flag; of the switches it does surface, that
is the one whose intent a material with unknowable contrast behind it would
defeat. `mac_window_high_contrast.png` pins it.

**A `cookies` login step is a dead end.** Braid embeds no browser. The step is
explained and the user is sent to the bridge's management chat, which can do
the same job. See `bridge_login_flow.dart`.

**The goldens doubled.** `mac_golden_test.dart` captures the window at
1280×800 in light, dark and high contrast, plus a conversation. The phone's
goldens cannot catch a regression here — they are taken on the other surface,
where every one of these values is different.
