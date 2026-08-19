import SwiftUI

/// The conversation list, or the one sentence explaining why there is not one.
///
/// Five states, the same five every other companion surface has — case for case,
/// because four hand-written renderers of one payload that disagreed about which
/// states exist would be worse than any of them. None of them is a blank screen.
struct WeftWatchInboxView: View {
  @EnvironmentObject private var store: WeftWatchStore

  /// The staleness tick.
  ///
  /// Nothing writes anything when a payload crosses `kSnapshotStaleAfter`; it
  /// simply stops being true. A minute is far finer than a twelve-hour boundary
  /// needs and is free while the screen is on, which is the only time this view
  /// exists at all.
  private let tick = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

  var body: some View {
    NavigationStack {
      Group {
        if store.state.rows.isEmpty {
          WeftWatchEmptyStateView(state: store.state)
        } else {
          List {
            ForEach(store.state.rows) { row in
              NavigationLink {
                WeftWatchReplyView(row: row)
              } label: {
                WeftWatchRowView(row: row, palette: store.state.snapshot?.palette ?? [:])
              }
            }
          }
          .listStyle(.carousel)
        }
      }
      .navigationTitle(WeftWatchStrings.inboxHeading)
    }
    .onReceive(tick) { _ in store.refresh() }
  }
}

/// One conversation.
///
/// `NavigationLink` rather than the widgets' `Link`, and that is the one real
/// structural difference between this and `WeftConversationRowView`: a widget
/// taps *out* of itself into the phone app through a `weft://chat/<id>` URL,
/// and this taps *into* a screen on the same device. The row therefore does not
/// use `SnapshotRow.link` at all — it is carried in the payload for the two
/// surfaces that do, and a watch that opened a deep link would be asking a
/// phone in another room to show something nobody is looking at.
///
/// Merged conversations are signalled two ways, neither of them colour alone:
/// the *number* of network dots, and the accessibility label. `ChatTile` on the
/// phone manages three; a row this size can carry two, which is the floor the
/// design notes set.
struct WeftWatchRowView: View {
  let row: WeftSnapshotRow
  let palette: [String: UInt32]

  var body: some View {
    HStack(alignment: .center, spacing: WeftWidgetTokens.spaceSM) {
      WeftNetworkDotsView(row: row, palette: palette)
      VStack(alignment: .leading, spacing: 2) {
        Text(row.title)
          .font(
            // Unread is what this surface exists to show, so it is carried by
            // weight as well as by the badge — the same "never one signal alone"
            // rule the merged indicator follows.
            WeftWidgetTokens.titleFont.weight(row.unreadCount > 0 ? .bold : .regular)
          )
          .lineLimit(1)
        if let preview = row.previewLine {
          // Already policy-filtered, already rendered per kind by `weft_notify`,
          // already cut at a grapheme boundary. Nothing here re-truncates it: a
          // second cut would be a second rule, measured in the wrong units.
          Text(preview)
            .font(WeftWidgetTokens.bodyFont)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }
      Spacer(minLength: 0)
      if row.unreadCount > 0 {
        WeftUnreadBadgeView(label: row.unreadLabel)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
  }

  /// Assembled rather than left to SwiftUI's default, which would read the
  /// title, the preview and the badge as three unrelated strings in layout
  /// order — so a merged conversation would be indistinguishable from a plain
  /// one and the unread count would arrive after the message it belongs to.
  private var accessibilityLabel: String {
    var parts = [row.title]
    if row.isMerged { parts.append(WeftWatchStrings.merged) }
    if row.unreadCount > 0 {
      parts.append(WeftWatchStrings.unreadCount(row.unreadCount))
    }
    if let preview = row.previewLine { parts.append(preview) }
    return parts.joined(separator: ", ")
  }
}

/// A state with nothing to show, saying why.
///
/// Every branch that is not a populated `ready` lands here, and each names its
/// own cause and, where there is one, the thing the wearer would do about it.
/// The stale and switched-off sentences are the phase brief's requirement in
/// literal form: *a clear "open Weft on your phone" state when the snapshot is
/// stale, disabled or absent*.
struct WeftWatchEmptyStateView: View {
  let state: WeftWatchState

  var body: some View {
    let copy = WeftWatchStrings.emptyState(for: state)
    VStack(spacing: WeftWidgetTokens.spaceXS) {
      Text(copy.title)
        .font(.headline)
        .multilineTextAlignment(.center)
      Text(copy.body)
        .font(WeftWidgetTokens.bodyFont)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .padding(.horizontal, WeftWidgetTokens.spaceSM)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Reply

/// Dictate, or tap one of six sentences.
///
/// **Nothing on this screen sends a message.** It hands a string to
/// `WeftWatchStore`, which asks the phone; the phone resolves the conversation,
/// picks the leg, sends, and answers. Everything about this screen follows from
/// that: the outcome is a state it waits for rather than an assumption it makes,
/// and it does not dismiss itself until the phone has confirmed.
///
/// Dictation is `TextFieldLink`, which opens the *system's* input picker — voice,
/// scribble, emoji, the compact keyboard, whichever this watch has. Not
/// `SFSpeechRecognizer`: that would mean a microphone permission, a locale to
/// pick, an on-device model to fail to download, and an app that could only be
/// replied to out loud.
struct WeftWatchReplyView: View {
  let row: WeftSnapshotRow

  @EnvironmentObject private var store: WeftWatchStore
  @Environment(\.dismiss) private var dismiss
  @State private var replyId: String?

  private var outcome: WeftWatchReplyState? { replyId.flatMap { store.replies[$0] } }

  var body: some View {
    Group {
      if let outcome {
        WeftWatchReplyOutcomeView(outcome: outcome)
      } else {
        List {
          TextFieldLink(prompt: Text(row.title)) {
            Label(WeftWatchStrings.replyDictate, systemImage: "mic.fill")
          } onSubmit: { text in
            let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // A cancelled dictation and an empty one are the same thing and
            // neither is an error: the wearer changed their mind, and the screen
            // stays where it was.
            guard !body.isEmpty else { return }
            replyId = store.send(chatId: row.chatId, body: body)
          }
          ForEach(WeftWatchStrings.cannedReplies, id: \.self) { canned in
            Button(canned) {
              replyId = store.send(chatId: row.chatId, body: canned)
            }
          }
        }
      }
    }
    .navigationTitle(row.title)
    .onChange(of: outcome) { _ in
      // The screen closes itself once the phone has confirmed, and only then. A
      // dismiss on tap would take the one surface that can report a failure away
      // before the failure arrives — which is the silently dropped reply this
      // whole path exists to make impossible.
      guard case .sent = outcome else { return }
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { dismiss() }
    }
  }
}

/// Sending, sent, or the sentence for why not.
///
/// A screen rather than a toast, because a failure here is the one thing a
/// wearer must not miss: the message they believe they sent did not go, and the
/// only place that can be said is the surface they are still looking at.
struct WeftWatchReplyOutcomeView: View {
  let outcome: WeftWatchReplyState

  var body: some View {
    VStack(spacing: WeftWidgetTokens.spaceSM) {
      switch outcome {
      case .sending:
        ProgressView()
        Text(WeftWatchStrings.replySending)
          .font(WeftWidgetTokens.bodyFont)
          .foregroundStyle(.secondary)
      case .sent(let network):
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(WeftWidgetTokens.brandPrimary)
        // The leg is named only for a merged conversation, where the phone had a
        // choice to make. A one-network chat reporting "via WhatsApp" would
        // spend a line of a very small screen on something the wearer could not
        // have changed.
        Text(network.map { "\(WeftWatchStrings.replySent) via \($0)" } ?? WeftWatchStrings.replySent)
          .font(.headline)
          .multilineTextAlignment(.center)
      case .failed(let failure):
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
        Text(WeftWatchStrings.replyFailure(failure))
          .font(WeftWidgetTokens.bodyFont)
          .multilineTextAlignment(.center)
      }
    }
    .padding(.horizontal, WeftWidgetTokens.spaceSM)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
