import SwiftUI

/// The two pieces of a conversation row that are **only** about the payload.
///
/// Split out of `WeftWidgetViews.swift` when the watch app arrived, and split on
/// a real line rather than a convenient one: everything here needs a
/// `WeftSnapshotRow` and `WeftWidgetTokens` and nothing else — no `WidgetKit`, no
/// `WeftWidgetState`, no timeline. That is exactly what makes it compilable into
/// a watch app, which is a plain SwiftUI `App` and has neither.
///
/// **Compiled into three targets from one file**: `WeftWidget` on iOS and macOS,
/// and `WeftWatch`. The same arrangement `ios/Shared/` has, one layer up — and
/// the reason is the one both other files give. A badge that capped at `99+` in
/// two places and `999+` in a third would be three surfaces disagreeing about a
/// number none of them computed.
///
/// What is deliberately *not* here is the row itself. A widget row is a `Link`
/// out to the phone app and a watch row is a `NavigationLink` into a screen on
/// the same device; they are the same layout for genuinely different reasons,
/// and folding them together would mean a parameter that decides what tapping
/// does.

/// The `99+` pill.
///
/// The label is `SnapshotRow.unreadLabel`, formatted on the phone. The cap is
/// `WeftUnreadBadge`'s and it is applied in Dart precisely so the same
/// conversation does not read `120` in the app and `99+` here, or the reverse.
struct WeftUnreadBadgeView: View {
  let label: String

  var body: some View {
    Text(label)
      .font(WeftWidgetTokens.labelFont.weight(.medium))
      .foregroundStyle(WeftWidgetTokens.brandOnPrimary)
      .padding(.horizontal, WeftWidgetTokens.spaceSM)
      .padding(.vertical, 2)
      .background(WeftWidgetTokens.brandPrimary, in: Capsule())
      .lineLimit(1)
      // A count is not a name. It stays visible on a locked screen for the same
      // reason the accessory exists at all — the number is the fact the user
      // asked this surface to show them, and it identifies no one.
      .accessibilityHidden(true)
  }
}

/// One dot per network feeding the conversation, in the payload's order.
///
/// Colours come from `InboxSnapshot.palette` — `ChatNetwork.brandColor`, carried
/// as an int, once per payload rather than once per row — and fall back to a
/// semantic colour when the payload names a network this build has never heard
/// of. That fallback is why the *count* of dots rather than their colour is what
/// says "merged": an unknown network still gets a dot.
///
/// Stacked vertically rather than in a row because the strip sits in a fixed
/// column to the left of the title, and a merged conversation must not push the
/// title further right than a plain one does.
struct WeftNetworkDotsView: View {
  let row: WeftSnapshotRow
  let palette: [String: UInt32]

  var body: some View {
    VStack(spacing: 2) {
      ForEach(row.networks.prefix(WeftWidgetTokens.maxNetworkDots), id: \.self) { network in
        Circle()
          .fill(colour(for: network))
          .frame(width: WeftWidgetTokens.dot, height: WeftWidgetTokens.dot)
      }
    }
    .frame(width: WeftWidgetTokens.dot)
    .accessibilityHidden(true)
  }

  private func colour(for network: String) -> Color {
    guard let brand = palette[network] else { return WeftWidgetTokens.unknownNetwork }
    return WeftWidgetTokens.color(fromARGB: brand)
  }
}
