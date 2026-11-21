/// The words for the domain's enums.
///
/// [MessageKind] and [DeliveryState] come out of `weft_domain` as bare values,
/// and something has to turn "this is a `MessageKind.voice`" into "Voice
/// message". That mapping used to live in `weft_design` as two top-level
/// functions returning English, which is the one place it cannot stay: a
/// package that hard-codes user-facing words is a package no locale can reach,
/// and giving it `AppL10n` would point a shared library at the app that
/// consumes it.
///
/// So the enum stays in the domain, the words stay in the app's ARB, and this
/// is the join. `docs/architecture/l10n-pipeline.md` describes the boundary in
/// general; every package that used to answer in English answers in a value
/// like these instead.
library;

import 'package:intl/intl.dart';
import 'package:weft_attachments/weft_attachments.dart';
import 'package:weft_autoreply/weft_autoreply.dart';
import 'package:weft_bridges/weft_bridges.dart';
import 'package:weft_call/weft_call.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_notify/weft_notify.dart';
import 'package:weft_search/weft_search.dart';

import '../services/ai/auto_reply_service.dart';
import '../services/ai/auto_reply_writer.dart';
import '../services/ai/quick_messages.dart';
import 'localisation.dart';

extension WeftDomainLabels on AppL10n {
  /// What a message *is*, for a reader who cannot see the bubble.
  ///
  /// The preview text answers "what does it say"; this answers "what kind of
  /// thing is it", which for a photo or a file is the only thing there is to
  /// say.
  String messageKind(MessageKind kind) => switch (kind) {
    MessageKind.image => messageKindPhoto,
    MessageKind.video => messageKindVideo,
    MessageKind.voice => messageKindVoice,
    MessageKind.audio => messageKindAudio,
    MessageKind.file => messageKindFile,
    MessageKind.sticker => messageKindSticker,
    MessageKind.location => messageKindLocation,
    MessageKind.poll => messageKindPoll,
    MessageKind.event => messageKindEvent,
    MessageKind.text => messageKindText,
  };

  /// A message's delivery state in words.
  ///
  /// Read and delivered are drawn with the same double tick and differ only in
  /// colour — the one distinction a colour-blind reader cannot make and a
  /// screen reader cannot see at all. Naming them is what makes the state exist
  /// for both. Returns an empty string for a state with nothing worth saying,
  /// which `semanticsSentence` then drops.
  String deliveryState(DeliveryState? state) => switch (state) {
    DeliveryState.sending => deliverySending,
    DeliveryState.sent => deliverySent,
    DeliveryState.delivered => deliveryDelivered,
    DeliveryState.read => deliveryRead,
    DeliveryState.failed => deliveryFailed,
    null => '',
  };
}

/// The words for the codes packages answer in.
///
/// `weft_bridges`, `weft_search` and `weft_attachments` describe a failure as
/// a value rather than a sentence, precisely so this file can be the only
/// place that turns one into words. Each carries an English `message` too,
/// which is what a log shows and what a caller with no translations falls back
/// to; where a code is present it wins.
extension WeftFailureLabels on AppL10n {
  /// Why a bridge could not be reached, in the reader's language.
  ///
  /// Null when the bridge sent a sentence of its own: those arrive in whatever
  /// language the bridge was configured in, and rewriting one would be
  /// replacing a specific answer with a general one.
  String? bridgeFailure(BridgeException error) => switch (error.failure) {
    null => null,
    BridgeFailure.rejected => bridgeErrorRejected,
    BridgeFailure.notFound => bridgeErrorNotFound,
    BridgeFailure.unavailable ||
    BridgeFailure.unreachable ||
    BridgeFailure.timeout => bridgeErrorUnavailable,
    BridgeFailure.other => bridgeErrorStatus(error.statusCode ?? 0),
  };

  /// Why the embedding endpoint failed, in the reader's language.
  String? embeddingFailure(EmbeddingException error) => switch (error.failure) {
    null => null,
    EmbeddingFailure.rejectedKey => embeddingErrorRejectedKey,
    EmbeddingFailure.notFound => embeddingErrorNotFound,
    EmbeddingFailure.rateLimited => embeddingErrorRateLimited,
    EmbeddingFailure.server => embeddingErrorServer(error.statusCode ?? 0),
    EmbeddingFailure.other => embeddingErrorOther(
      error.statusCode ?? 0,
      error.message,
    ),
  };

  /// Why an attachment will not be sent, in the reader's language.
  ///
  /// The size and the limit come off the rejection rather than out of its
  /// sentence, because a language that writes numbers differently has to be
  /// able to format them itself.
  String attachmentRejection(UploadRejection rejection) =>
      switch (rejection.reason) {
        UploadRejectionReason.empty => attachmentRejectedEmpty,
        UploadRejectionReason.tooLarge => attachmentRejectedTooLarge(
          formatAttachmentSize(rejection.sizeBytes ?? 0),
          formatAttachmentSize(rejection.limitBytes ?? 0),
        ),
        UploadRejectionReason.unsupported => attachmentRejectedUnnamed,
      };
}

/// The words for auto-reply's codes.
///
/// The same join as [WeftFailureLabels], for the same reason: `weft_autoreply`
/// answers in [AutoReplyRefusal] and the writer in [AutoReplyOutcome], and
/// neither can reach `AppL10n`. Kept in its own extension because these are
/// not failures — half of them are the feature working exactly as configured,
/// and a user reading "cooling down" should not be reading it under a heading
/// that says something went wrong.
extension WeftAutoReplyLabels on AppL10n {
  /// Who a rule answers, in one short phrase for the rule list.
  ///
  /// Counts rather than names for the two set-shaped audiences: a rule aimed at
  /// nine people would otherwise take four lines of a subtitle, and the names
  /// are one tap away in the editor.
  String autoReplyAudience(AutoReplyAudience audience) => switch (audience) {
    EveryoneAudience() => autoReplyAudienceEveryone,
    NetworkAudience(:final networks) => autoReplyAudienceNetworksNamed(
      networkNames(networks.toList()),
    ),
    LabelAudience(:final label) => autoReplyAudienceLabelNamed(label),
    ContactAudience(:final ids) => autoReplyAudienceContactCount(ids.length),
  };

  /// Why the model produced nothing, or that it did.
  String autoReplyOutcome(AutoReplyOutcome outcome) => switch (outcome) {
    AutoReplyOutcome.sent => autoReplyOutcomeSent,
    AutoReplyOutcome.notConfigured => autoReplyOutcomeNotConfigured,
    AutoReplyOutcome.unreachable => autoReplyOutcomeUnreachable,
    AutoReplyOutcome.timedOut => autoReplyOutcomeTimedOut,
    AutoReplyOutcome.refused => autoReplyOutcomeRefused,
    AutoReplyOutcome.declined => autoReplyOutcomeDeclined,
    AutoReplyOutcome.sendFailed => autoReplyOutcomeSendFailed,
  };

  /// Why the engine held back. Only the refusals the service reports reach
  /// here — the rest are true of ordinary traffic and are never shown.
  String autoReplyRefusal(AutoReplyRefusal refusal) => switch (refusal) {
    AutoReplyRefusal.conversationCap => autoReplyRefusalCap(
      kAutoReplyMaxPerConversation,
    ),
    AutoReplyRefusal.cooling => autoReplyRefusalCooling,
    AutoReplyRefusal.outsideSchedule => autoReplyRefusalOutsideSchedule,
    _ => autoReplyRefusalOther,
  };

  /// One line for one attempt in the log.
  String autoReplyAttemptOutcome(AutoReplyAttempt attempt) {
    final refusal = attempt.refusal;
    if (refusal != null) return autoReplyRefusal(refusal);
    final outcome = attempt.outcome;
    return outcome == null ? autoReplyRefusalOther : autoReplyOutcome(outcome);
  }

  /// A weekday's short name, from `DateTime.monday`…`DateTime.sunday`.
  ///
  /// Off `intl`'s own symbols rather than a switch over seven ARB keys: the
  /// names are already translated for every locale Sennit ships, and a second
  /// set in the ARB would be seven more strings to keep in step with the
  /// calendar.
  String autoReplyWeekday(int weekday) {
    final symbols = DateFormat.E(
      localeName,
    ).dateSymbols.STANDALONESHORTWEEKDAYS;
    // `intl` indexes from Sunday; `DateTime` from Monday.
    return symbols[weekday % 7];
  }
}

/// The words `weft_notify` and `weft_snapshot` render with.
///
/// Both draw text the operating system shows — a lock screen, a home-screen
/// widget, a watch face — and neither has a widget tree or an ARB file. They
/// declare what they need and this fills it in.
WeftNotifyStrings weftNotifyStringsFrom(AppL10n l10n) => WeftNotifyStrings(
  hiddenPreview: l10n.notificationHiddenPreview,
  messageKind: l10n.messageKind,
);

/// Whether a conversation can carry a call, in the reader's language.
///
/// `weft_call` answers with a [CallAvailability] — a target or a
/// [CallBlocker], plus the messengers a bridged sentence has to name — and
/// this is the only place that turns one into words.
extension WeftCallLabels on AppL10n {
  String callAvailability(CallAvailability availability) =>
      switch (availability) {
        CallReady(:final target) => callAvailabilityReady(target.peer.label),
        CallBlocked(reason: CallBlocker.group) => callBlockedGroup,
        CallBlocked(reason: CallBlocker.unknownPeer) => callBlockedUnknownPeer,
        CallBlocked(:final networks) => callBlockedBridged(
          networkNames(networks),
        ),
      };

  /// "WhatsApp", "WhatsApp and Signal", "WhatsApp, Signal and Telegram".
  ///
  /// The list separator is the language's own, which is why this is not a
  /// `join(', ')` at the call site.
  String networkNames(List<ChatNetwork> networks) {
    final names = networks.map((n) => n.label).toList(growable: false);
    return switch (names.length) {
      0 => callBlockedThisConversation,
      1 => names.single,
      2 => networkNamesTwo(names.first, names.last),
      _ => networkNamesMany(
        names.sublist(0, names.length - 1).join(', '),
        names.last,
      ),
    };
  }
}

/// The words for a quick message: the preset titles live in the ARB, so an
/// untouched default follows the app language.
extension WeftQuickMessageLabels on AppL10n {
  String quickMessagePreset(QuickMessagePreset preset) => switch (preset) {
    QuickMessagePreset.birthday => quickMessagePresetBirthday,
    QuickMessagePreset.congratulations => quickMessagePresetCongratulations,
    QuickMessagePreset.getWell => quickMessagePresetGetWell,
    QuickMessagePreset.thanks => quickMessagePresetThanks,
    QuickMessagePreset.onMyWay => quickMessagePresetOnMyWay,
    QuickMessagePreset.newYear => quickMessagePresetNewYear,
  };

  /// The title [message] is shown under: the user's, else its preset's.
  String quickMessageTitle(QuickMessage message) {
    final own = message.title?.trim() ?? '';
    if (own.isNotEmpty) return own;
    final preset = message.preset;
    return preset == null ? '' : quickMessagePreset(preset);
  }
}
