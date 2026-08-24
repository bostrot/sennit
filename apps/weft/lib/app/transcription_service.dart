import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matrix/matrix.dart' as sdk;
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_store/weft_store.dart' show StoredTranscript;
import 'package:weft_transcribe/weft_transcribe.dart';

import 'search_providers.dart';
import 'session_providers.dart';
import 'stores.dart';

/// Transcribes voice messages on demand and remembers the result.
///
/// Transcripts are written into the search index — that is what makes a voice
/// note findable by its spoken words — and kept in a per-session cache the
/// chat view reads for display.
class TranscriptionService {
  TranscriptionService(this._ref);

  final Ref _ref;

  /// eventId → transcript, for bubbles already on screen.
  final Map<String, Transcript> _cache = {};

  /// Events being transcribed right now, so a rebuild can't start a second
  /// request for the same clip.
  final Set<String> _inFlight = {};

  /// Events that already failed this session; retried only by explicit tap,
  /// not by every scroll past the bubble.
  final Set<String> _failed = {};

  /// The session cache, then the database: a transcription done last week is
  /// work already paid for, and it survives restarts now.
  Transcript? cached(String eventId, {String? roomId}) {
    final hot = _cache[eventId];
    if (hot != null) return hot;
    if (roomId == null) return null;

    final stored = storesOrNull(_ref)?.transcripts.byEvent(eventId, roomId);
    if (stored == null) return null;
    return _cache[eventId] = Transcript(
      text: stored.text,
      provider: stored.provider,
      language: stored.language,
    );
  }

  /// Whether any provider — on-device or endpoint — is usable right now.
  Future<bool> get isConfigured async =>
      await _ref.read(transcriptionProviderProvider.future) != null;

  /// Downloads, decrypts and transcribes one voice message.
  ///
  /// [languageOverride] backs the "re-transcribe in the right language" action:
  /// auto-detection sometimes picks wrong on short clips, and the fix is a
  /// context action, not a settings hunt.
  /// One transcription at a time. whisper.cpp saturates the big cores on
  /// its own; two jobs at once are both slower than the same two run back
  /// to back — and the auto pass plus a manual tap was exactly that.
  Future<void> _jobQueue = Future<void>.value();

  Future<Transcript> transcribe(
    WeftMessage message, {
    String? languageOverride,
  }) {
    final job = _jobQueue.then(
      (_) => _transcribeNow(message, languageOverride: languageOverride),
    );
    _jobQueue = job.then((_) {}, onError: (_) {});
    return job;
  }

  Future<Transcript> _transcribeNow(
    WeftMessage message, {
    String? languageOverride,
  }) async {
    final provider = await _ref.read(transcriptionProviderProvider.future);
    if (provider == null) {
      throw const TranscriptionException(
        'No transcription set up yet. Either download a Whisper model under '
        'Settings → Endpoints → Local models and switch it on for voice, or '
        'configure an endpoint.',
      );
    }

    final client = _ref.read(matrixSessionProvider).client;
    final room = client.getRoomById(message.roomId);
    final event = room == null
        ? null
        : await room.getEventById(message.eventId);
    if (event == null) {
      throw const TranscriptionException('That message is no longer available');
    }

    // Handles both encrypted and plain attachments; decryption happens locally
    // before anything leaves the device.
    final file = await event.downloadAndDecryptAttachment();

    final transcript = await provider.transcribe(
      TranscriptionRequest(
        audio: Uint8List.fromList(file.bytes),
        filename: file.name.isEmpty ? 'voice.ogg' : file.name,
        mimeType: file.mimeType,
        languageHint:
            languageOverride ??
            _ref.read(storesProvider).settings.getString('transcribe.language'),
      ),
    );

    _cache[message.eventId] = transcript;

    // Persisted, then indexed: the row is the transcript's home across
    // restarts, and the index copy is what makes the spoken words findable —
    // by keyword through FTS, and by meaning once the embedding queue drains.
    if (!transcript.isEmpty) {
      final stores = _ref.read(storesProvider);
      stores.transcripts.save(
        StoredTranscript(
          eventId: message.eventId,
          roomId: message.roomId,
          text: transcript.text,
          provider: transcript.provider,
          language: transcript.language,
        ),
      );
      stores.search.indexMessage(
        message.copyWith(transcript: transcript.text),
        chatId: message.roomId,
        chatTitle: message.senderName,
      );
    }
    return transcript;
  }

  /// Transcribes recent untranscribed voice messages, when the user opted in.
  ///
  /// Capped to the newest few per call: auto-transcribe exists for incoming
  /// messages, and paging deep into history must not turn into a paid batch
  /// job the user never asked for.
  Future<void> autoTranscribe(
    List<WeftMessage> visible, {
    int cap = 5,
    void Function()? onEach,
  }) async {
    // Read the bootstrap gate, not storesProvider: a chat view can page while
    // the stores are still opening (or, in a widget test, never open at all),
    // and reading the erroring provider reports a StateError to the zone that
    // no try/catch here can intercept. No stores means nobody opted in.
    final stores = _ref.read(storesBootstrapProvider).value;
    if (stores == null) return;
    final settings = stores.settings;
    if (!settings.getBool('transcribe.auto')) return;
    if (await _ref.read(transcriptionProviderProvider.future) == null) return;

    final candidates = visible
        .where(
          (m) =>
              m.canTranscribe &&
              m.transcript == null &&
              !_cache.containsKey(m.eventId) &&
              !_inFlight.contains(m.eventId) &&
              !_failed.contains(m.eventId),
        )
        .take(cap);

    for (final message in candidates) {
      _inFlight.add(message.eventId);
      try {
        await transcribe(message);
        onEach?.call();
      } on Exception {
        _failed.add(message.eventId);
      } finally {
        _inFlight.remove(message.eventId);
      }
    }
  }

  /// Lets the settings screen verify an endpoint with a tiny silent clip
  /// before the user trusts it with real messages.
  Future<bool> probe() async {
    final provider = await _ref.read(transcriptionProviderProvider.future);
    if (provider == null) return false;
    try {
      await provider.transcribe(
        TranscriptionRequest(
          audio: Uint8List(1024),
          filename: 'probe.wav',
          mimeType: 'audio/wav',
        ),
      );
      return true;
    } on TranscriptionException {
      return false;
    }
  }
}

final transcriptionServiceProvider = Provider<TranscriptionService>(
  TranscriptionService.new,
);

/// Bumped when a transcript lands so open chat views refresh.
class TranscriptRevision extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

final transcriptRevisionProvider = NotifierProvider<TranscriptRevision, int>(
  TranscriptRevision.new,
);

/// Re-exported here so the chat view has one import for voice features.
sdk.Client clientOf(Ref ref) => ref.read(matrixSessionProvider).client;
