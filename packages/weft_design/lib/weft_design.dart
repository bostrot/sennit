/// Weft's design system: tokens, themes and shared components.
///
/// Nothing here knows about Matrix, bridges or storage — components take plain
/// `weft_domain` values, which is what keeps them golden-testable in isolation.
library;

export 'src/bidi.dart';
export 'src/components/chat_tile.dart';
export 'src/components/draggable_sheet.dart';
export 'src/components/network_glyph.dart';
export 'src/components/network_rail.dart';
export 'src/components/unread_badge.dart';
export 'src/components/brand_mark.dart';
export 'src/components/weft_avatar.dart';
export 'src/contrast.dart';
export 'src/focus.dart';
export 'src/mac/mac_controls.dart';
export 'src/mac/mac_glass.dart';
export 'src/mac/mac_panels.dart';
export 'src/mac/mac_sidebar.dart';
export 'src/mac/mac_toolbar.dart';
export 'src/labelled_field.dart';
export 'src/reading_pane.dart';
export 'src/selection.dart';
export 'src/semantics.dart';
export 'src/strings.dart';
export 'src/surface.dart';
export 'src/tap_target.dart';
export 'src/theme.dart';
export 'src/tokens.dart';
export 'src/weft_app_bar.dart';
