## Unreleased

* `MacSearchField` takes a `clearLabel` for its clear button's tooltip and
  accessibility label, which was fixed English. The button now answers across
  the field's full 24pt height instead of only on its 13pt glyph, and the focus
  ring is painted over the field rather than inset into it, so focusing no
  longer shrinks the button or nudges the contents.

## 0.0.2

* Added `WeftPalette.callAccept` and `WeftPalette.callDecline`. Fixed colours
  rather than scheme-derived ones, and deliberately not `ColorScheme.error`:
  green-answers and red-hangs-up are learned from every phone the user has held,
  and an error is something that went wrong while hanging up is not.

## 0.0.1

* TODO: Describe initial release.
