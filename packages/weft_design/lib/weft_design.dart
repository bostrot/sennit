/// Weft's design system: tokens, themes and shared components.
///
/// Nothing here knows about Matrix, bridges or storage — components take plain
/// `weft_domain` values, which is what keeps them golden-testable in isolation.
library;

export 'src/components/chat_tile.dart';
export 'src/components/network_glyph.dart';
export 'src/components/network_rail.dart';
export 'src/components/weft_avatar.dart';
export 'src/contrast.dart';
export 'src/focus.dart';
export 'src/semantics.dart';
export 'src/theme.dart';
export 'src/tokens.dart';
