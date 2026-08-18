import 'dart:convert';

import 'package:weft_call/weft_call.dart';

/// Reads what an offer/answer settled on.
///
/// `weft_call` records a [CodecSummary] on the session and never produces one:
/// its doc comment says the SDP belongs to the media engine, and this is the
/// media engine's half of that bargain. It exists as a free function in its own
/// file rather than as a method on [WebRTCMediaEngine] so that it is testable
/// without a peer connection — the parsing is the only part of the engine with
/// a decision in it, and "the call sounded bad" is unanswerable without the
/// answer being right.
///
/// Read from the **answer**, not the offer. An offer lists everything the
/// sender could do; only the answer says what the two of them agreed on, and
/// the first payload type on its `m=` line is the one that will actually be
/// sent.
///
/// Returns null when nothing was readable, so a caller can leave the session's
/// existing summary alone rather than overwriting it with blanks.
CodecSummary? codecSummaryFromSdp(String sdp) {
  String? audio;
  String? video;

  // The section being read, and the payload type it prefers. Both reset at
  // every `m=` line, because an `a=rtpmap` belongs to the section above it and
  // attributing it to the wrong one names a video codec for the audio stream.
  String? kind;
  String? payloadType;

  for (final line in const LineSplitter().convert(sdp)) {
    if (line.startsWith('m=')) {
      final parts = line.substring(2).split(' ');
      kind = null;
      payloadType = null;
      if (parts.length < 4) continue;
      // Port 0 is a rejected section — how a video call is downgraded to audio
      // during renegotiation. Naming its codec would put a camera's worth of
      // detail on a call that no longer carries video.
      if (parts[1] == '0') continue;
      kind = parts[0];
      payloadType = parts[3];
      continue;
    }

    if (kind == null || payloadType == null) continue;
    if (!line.startsWith('a=rtpmap:')) continue;

    final rtpmap = line.substring('a=rtpmap:'.length).split(' ');
    if (rtpmap.length < 2 || rtpmap[0] != payloadType) continue;

    // `opus/48000/2` → `opus`. The clock rate and channel count are real
    // information and belong nowhere near a call screen.
    final name = rtpmap[1].split('/').first;
    if (name.isEmpty) continue;
    switch (kind) {
      case 'audio':
        audio ??= name;
      case 'video':
        video ??= name;
    }
  }

  if (audio == null && video == null) return null;
  return CodecSummary(audio: audio, video: video);
}
