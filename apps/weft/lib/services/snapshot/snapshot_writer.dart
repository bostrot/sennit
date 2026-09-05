import 'package:clock/clock.dart';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_snapshot/weft_snapshot.dart';
import 'package:weft_store/weft_store.dart';

import '../../app/l10n_labels.dart';
import '../../app/localisation.dart';

/// The privacy gate on companion surfaces, as the app stores it.
///
/// [SnapshotPolicy] is the pure-Dart half — what a row is allowed to say — and
/// deliberately knows nothing about `SettingsStore`, which drags in Flutter and
/// sqlite. This is the other half, and it is shaped after [LinkPreviewSettings]
/// on purpose: a `fromStore`, a `writeTo`, an `off` constant that a failed read
/// falls back to, and a per-network exclusion under the same `privacy.` keys.
///
/// **Why two surface switches and one policy.** [widgets] and [watch] are
/// separate disclosures — a home screen is read by whoever is standing next to
/// it and a wrist is not — but they are fed by *one* payload, because writing
/// the same rows twice into the same container would double the disclosure
/// without adding a surface. So the two flags decide who is allowed to render,
/// and [policy] is what the payload contains. Turning both off closes the gate:
/// [SnapshotPolicy.enabled] is `widgets || watch`, and the writer then writes
/// the switched-off payload rather than a filtered one.
///
/// The flags travel to the platform *beside* the payload rather than inside it,
/// for the same reason the payload's key names are a cross-language contract:
/// `SnapshotCodec` is the only thing that writes that JSON, its shape is pinned
/// by tests in `weft_snapshot`, and a sixth field bolted on here would be a
/// second writer of a format two hand-written parsers already read.
@immutable
class SnapshotSettings {
  const SnapshotSettings({
    this.widgets = false,
    this.watch = false,
    this.includePreviews = false,
    this.includeSenderNames = false,
    this.excludedNetworks = const {},
  });

  /// Reads the gate out of the settings store.
  ///
  /// Every key defaults to off, so a store that has never seen these keys —
  /// which is every install before this build — reads as [off].
  factory SnapshotSettings.fromStore(SettingsStore settings) {
    final excluded = settings.getJson(WeftSettings.snapshotExcludedNetworks);
    final networks = excluded?['networks'];
    return SnapshotSettings(
      widgets: settings.getBool(WeftSettings.snapshotWidgets),
      watch: settings.getBool(WeftSettings.snapshotWatch),
      includePreviews: settings.getBool(WeftSettings.snapshotPreviews),
      includeSenderNames: settings.getBool(WeftSettings.snapshotSenderNames),
      excludedNetworks: {
        if (networks is List)
          for (final id in networks)
            if (id is String) id,
      },
    );
  }

  /// Off, with nothing disclosed. What an app that has never been configured is
  /// in, and what a failed settings read falls back to.
  static const SnapshotSettings off = SnapshotSettings();

  /// Whether home screen widgets — Glance on Android, WidgetKit on Apple —
  /// may render the snapshot.
  final bool widgets;

  /// Whether the watch companions may render it.
  final bool watch;

  /// Whether a row carries what the last message said.
  final bool includePreviews;

  /// Whether a row carries the conversation's title, the last sender's name and
  /// its avatar. See [SnapshotPolicy.includeSenderNames] for why the avatar
  /// travels under this flag rather than one of its own.
  final bool includeSenderNames;

  /// `ChatNetwork.id` strings that never reach a companion surface.
  final Set<String> excludedNetworks;

  /// Whether anything at all is written for a surface to read.
  bool get anySurface => widgets || watch;

  /// What the payload is allowed to contain.
  ///
  /// [SnapshotPolicy.maxRows] is left at its default: it is sized off the widest
  /// renderer rather than off anything the user chose, and a settings screen
  /// offering "how many conversations" would be asking them to tune a number
  /// whose only visible effect is on a surface they cannot see while they tune
  /// it.
  SnapshotPolicy get policy => SnapshotPolicy(
    enabled: anySurface,
    includePreviews: includePreviews,
    includeSenderNames: includeSenderNames,
    excludedNetworks: excludedNetworks,
  );

  /// Whether [network] may appear on a companion surface at all.
  bool allows(ChatNetwork network) => policy.allows(network);

  void writeTo(SettingsStore settings) {
    settings.setBool(WeftSettings.snapshotWidgets, value: widgets);
    settings.setBool(WeftSettings.snapshotWatch, value: watch);
    settings.setBool(WeftSettings.snapshotPreviews, value: includePreviews);
    settings.setBool(
      WeftSettings.snapshotSenderNames,
      value: includeSenderNames,
    );
    settings.setJson(WeftSettings.snapshotExcludedNetworks, {
      'networks': excludedNetworks.toList()..sort(),
    });
  }

  SnapshotSettings copyWith({
    bool? widgets,
    bool? watch,
    bool? includePreviews,
    bool? includeSenderNames,
    Set<String>? excludedNetworks,
  }) => SnapshotSettings(
    widgets: widgets ?? this.widgets,
    watch: watch ?? this.watch,
    includePreviews: includePreviews ?? this.includePreviews,
    includeSenderNames: includeSenderNames ?? this.includeSenderNames,
    excludedNetworks: excludedNetworks ?? this.excludedNetworks,
  );

  @override
  bool operator ==(Object other) =>
      other is SnapshotSettings &&
      other.widgets == widgets &&
      other.watch == watch &&
      other.includePreviews == includePreviews &&
      other.includeSenderNames == includeSenderNames &&
      setEquals(other.excludedNetworks, excludedNetworks);

  @override
  int get hashCode => Object.hash(
    widgets,
    watch,
    includePreviews,
    includeSenderNames,
    Object.hashAllUnordered(excludedNetworks),
  );

  @override
  String toString() =>
      'SnapshotSettings(widgets: $widgets, watch: $watch, '
      'previews: $includePreviews, names: $includeSenderNames, '
      'excluded: $excludedNetworks)';
}

/// The shared container, as the writer needs to see it.
///
/// A seam for the same reason [StagedShareGateway] is: behind it is a method
/// channel and a directory this process shares with three others, and every
/// decision [SnapshotWriter] makes — what to write, when not to, what to delete
/// — is a decision that can be wrong without a device being involved. The real
/// implementation is [WeftSnapshotContainer]; a test's is a list.
abstract interface class SnapshotGateway {
  /// Writes [json] where the companion surfaces will find it, tells them which
  /// of them may render it, and asks the platform to redraw.
  ///
  /// Returns false when the container could not be written — no channel on this
  /// platform, or a build with no App Group entitlement. False is a refusal to
  /// have stored anything, which the writer reads as "try again next tick"
  /// rather than as an error.
  Future<bool> writeSnapshot(
    String json, {
    required bool widgets,
    required bool watch,
  });

  /// Removes the payload entirely.
  ///
  /// Deliberately distinct from writing a switched-off one. An *absent* payload
  /// is how a surface tells "nobody is signed in" from "signed in, and this is
  /// switched off in Settings" — see [InboxSnapshot] for the three states and
  /// why each needs its own answer on screen.
  Future<void> clearSnapshot();
}

/// Keeps the shared container in step with the inbox.
///
/// The Dart half of every companion surface. `buildSnapshot` decides *what* a
/// row may say, the platform channel decides where the bytes land, and this
/// sits between them: it watches the chat list, applies the current
/// [SnapshotSettings], encodes, and calls the channel — or, far more often,
/// decides not to.
///
/// **The diff is the whole point**, the same way it is for [ShareShortcutService]
/// and for the same reason. `watchChats` emits on a read receipt, a typing
/// indicator, a presence change, a message in a conversation past the row cap.
/// A widget's contents change on a small fraction of those, and a write that
/// changes nothing still costs a file write, a `WidgetCenter` reload and — on
/// Android — a broadcast that re-lays out every home screen the widget is on.
///
/// **What the diff deliberately ignores, and what it deliberately does not.**
/// [InboxSnapshot.generatedAt] moves on every build, so comparing encoded bytes
/// would find every tick different and the diff would never fire. It is
/// excluded, and the cost of excluding it is paid back by [rewriteAfter]: a
/// payload that is never rewritten eventually crosses [kSnapshotStaleAfter] and
/// the surfaces start saying "open Braid on your phone" while the app is running
/// and the counts are correct. The surface flags *are* part of the key, because
/// turning the watch off while the widget stays on changes nothing in the
/// payload and everything about who may draw it.
class SnapshotWriter {
  SnapshotWriter({
    required SnapshotGateway gateway,
    SnapshotCodec codec = const SnapshotCodec(),
    this.rewriteAfter = const Duration(hours: 3),
  }) : _gateway = gateway,
       _codec = codec;

  final SnapshotGateway _gateway;
  final SnapshotCodec _codec;

  /// How long an unchanged payload is left alone before being written again.
  ///
  /// A quarter of [kSnapshotStaleAfter], so a snapshot is refreshed three times
  /// over before a surface would begin to doubt it, and a phone that is picked
  /// up once an afternoon never shows the stale state while it is in the user's
  /// hand. Not shorter: the whole point of the diff is that a quiet inbox costs
  /// nothing, and the cheapest write is still a home screen re-layout.
  final Duration rewriteAfter;

  /// The most recent chat list, or null when there is nothing this writer is
  /// entitled to publish.
  ///
  /// Null before the first [refresh] and again after [clear], and both mean the
  /// same thing: nobody is signed in. A settings change arriving in that state
  /// is recorded and stops there, rather than writing a snapshot of an inbox
  /// this process can no longer see.
  List<Chat>? _chats;

  SnapshotSettings _settings = SnapshotSettings.off;

  /// What the container was last told, and when.
  ///
  /// Null after a refusal as well as after a [clear]: a platform that answered
  /// false stored nothing, and remembering what it was asked for would mean
  /// never asking again for as long as the app runs. The same reading
  /// [ShareShortcutService] gives a publish that reached nothing.
  _WrittenSnapshot? _written;

  /// A write is in flight.
  bool _busy = false;

  /// A [refresh] or [applySettings] arrived while one was. Its inputs are
  /// already in [_chats] and [_settings]; this only records that the pass in
  /// flight is looking at a stale pair.
  bool _restale = false;

  /// The snapshot the container was last told to hold, for a test and for the
  /// settings screen's "last written" line.
  @visibleForTesting
  InboxSnapshot? get written => _written?.snapshot;

  /// The gate this writer is currently applying.
  SnapshotSettings get settings => _settings;

  /// Rebuilds the snapshot from [chats] and writes it, unless it matches what
  /// the container already holds.
  ///
  /// Safe to call on every inbox tick — that is what it is for. Overlapping
  /// calls coalesce rather than queue: a stream that ticks while the channel
  /// call is in flight wants the *newest* list written once, not every
  /// intermediate list written in turn.
  Future<void> refresh(List<Chat> chats, {DateTime? now}) async {
    _chats = List.of(chats);
    await _write(now: now);
  }

  /// Applies a changed gate, and writes immediately.
  ///
  /// Immediately, and not on the next inbox tick, because the tick may be
  /// minutes away: someone who has just switched previews off has to see the
  /// widget stop showing them before they put the phone down, or they will
  /// reasonably conclude the switch did nothing.
  Future<void> applySettings(SnapshotSettings settings, {DateTime? now}) async {
    if (settings == _settings) return;
    _settings = settings;
    await _write(now: now);
  }

  /// Removes the payload and forgets what was in it.
  ///
  /// Called on sign-out and on soft sign-out. A signed-out phone whose home
  /// screen still lists four conversations by name has handed them to whoever
  /// picks it up, and a widget is long-lived precisely because nothing else
  /// will collect it. The lock screen is the same argument one step further:
  /// the Lock Screen accessory renders while the device is locked, so what it
  /// may show has to be decided before the lock, not after it.
  ///
  /// [_chats] is dropped first so a write already in flight finds nothing to
  /// write on its next pass and stops, rather than racing the removal with a
  /// payload it built before the user signed out.
  Future<void> clear() async {
    _chats = null;
    _written = null;
    await _gateway.clearSnapshot();
  }

  Future<void> _write({DateTime? now}) async {
    if (_busy) {
      _restale = true;
      return;
    }
    _busy = true;
    try {
      do {
        _restale = false;
        await _writeOnce(now: now);
      } while (_restale);
    } finally {
      _busy = false;
    }
  }

  Future<void> _writeOnce({DateTime? now}) async {
    final chats = _chats;
    if (chats == null) return;

    final at = now ?? clock.now();
    // The device's locale, not a widget's: a widget row is drawn by the system
    // from a file this writes, possibly while the app is not running.
    final l10n = weftPlatformL10n();
    final snapshot = buildSnapshot(
      chats: chats,
      policy: _settings.policy,
      now: at,
      words: weftNotifyStringsFrom(l10n),
      redactedTitle: l10n.snapshotRedactedRowTitle,
      deletedPreview: l10n.chatMessageDeleted,
    );

    final last = _written;
    if (last != null &&
        last.widgets == _settings.widgets &&
        last.watch == _settings.watch &&
        _sameContent(last.snapshot, snapshot) &&
        at.difference(last.at) < rewriteAfter) {
      return;
    }

    final stored = await _gateway.writeSnapshot(
      _codec.encode(snapshot),
      widgets: _settings.widgets,
      watch: _settings.watch,
    );
    _written = stored
        ? _WrittenSnapshot(
            snapshot: snapshot,
            widgets: _settings.widgets,
            watch: _settings.watch,
            at: at,
          )
        : null;
  }

  /// Whether two snapshots would render identically.
  ///
  /// Everything [InboxSnapshot] equality compares except [InboxSnapshot.generatedAt]
  /// — which differs on every single build and is not a thing any surface draws,
  /// only a thing they judge staleness by. Staleness is handled by
  /// [rewriteAfter] instead, which is a decision about *when* to write rather
  /// than about what changed.
  static bool _sameContent(InboxSnapshot a, InboxSnapshot b) =>
      a.enabled == b.enabled &&
      a.totalUnread == b.totalUnread &&
      a.version == b.version &&
      const ListEquality<SnapshotRow>().equals(a.rows, b.rows);
}

/// What the container holds, as the writer remembers it.
@immutable
class _WrittenSnapshot {
  const _WrittenSnapshot({
    required this.snapshot,
    required this.widgets,
    required this.watch,
    required this.at,
  });

  final InboxSnapshot snapshot;
  final bool widgets;
  final bool watch;
  final DateTime at;
}

/// The shared container over `com.bostrot.weft/snapshot`.
///
/// Three implementations behind one channel name, because there are three
/// containers and no portable one: Android writes a `SharedPreferences` file
/// and broadcasts an app widget update, iOS and macOS write into the App Group
/// directory and reload the WidgetKit timelines. Every other platform has no
/// handler at all, which surfaces as [MissingPluginException] and is answered
/// here as "nothing was stored" — the same answer an unentitled iPhone gives,
/// and the reason [SnapshotWriter] can be wired up unconditionally.
///
/// ## Why a channel of its own
///
/// The same argument `WeftShareChannel` makes. `/intents` is `MainActivity`'s
/// and exists only on Android; this has to exist on three platforms, it touches
/// no state anything else writes, and its methods are disjoint from every other
/// channel's. A second front door onto one shortcut set was the thing that
/// argument was against, and there is no shared state here to race on.
///
/// ## What crosses it
///
/// * `writeSnapshot(json:widgets:watch:)` — the encoded [InboxSnapshot], plus
///   which surfaces may render it. The JSON crosses unparsed: `SnapshotCodec`
///   is the only encoder, its key names are the contract the hand-written Swift
///   and Kotlin readers are written against, and a second description of that
///   shape on this side is a second thing to keep in step.
/// * `clearSnapshot()` — sign-out. Deletes rather than blanking, because an
///   absent payload is a state the surfaces render differently.
class WeftSnapshotContainer implements SnapshotGateway {
  WeftSnapshotContainer({@visibleForTesting MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('com.bostrot.weft/snapshot');

  final MethodChannel _channel;

  @override
  Future<bool> writeSnapshot(
    String json, {
    required bool widgets,
    required bool watch,
  }) async =>
      await _invoke<bool>('writeSnapshot', {
        'json': json,
        'widgets': widgets,
        'watch': watch,
      }) ??
      false;

  @override
  Future<void> clearSnapshot() async {
    await _invoke<void>('clearSnapshot');
  }

  /// [method], or null for every way the platform can decline to answer.
  ///
  /// Both branches are ordinary rather than exceptional. [MissingPluginException]
  /// is every platform with no companion surfaces — Linux, Windows, and a
  /// widget test. [PlatformException] is a container the build is not entitled
  /// to reach, which is what an unsigned CI build and a stale provisioning
  /// profile both look like. Neither is worth throwing out of a chat-list
  /// listener that runs on every message.
  Future<T?> _invoke<T>(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      debugPrint('weft: snapshot container refused $method: ${error.message}');
      return null;
    }
  }
}
