import 'package:meta/meta.dart';
import 'package:weft_domain/weft_domain.dart';

import 'similarity.dart';

/// Why the scorer thinks two handles are the same person.
///
/// Surfaced verbatim in the merge UI. A suggestion the user can't understand is
/// a suggestion they won't trust, so every signal carries its own explanation.
enum MergeSignal {
  phoneExact('Same phone number', 0.95),
  emailExact('Same email address', 0.90),

  /// Identical full names on two different networks.
  ///
  /// Weighted above the suggest threshold deliberately: in practice bridges
  /// expose almost nothing else. Phone numbers only survive on some networks
  /// (Signal moved to opaque account ids), emails essentially never, and
  /// avatars are not compared until they have been fetched. Without this,
  /// merge suggestions were mathematically impossible — the strongest
  /// available evidence, a name matching exactly, scored 0.50 against a 0.55
  /// bar. It is still a *suggestion*: nothing merges without a tap.
  nameExact('Identical name', 0.62),

  nameSimilar('Very similar name', 0.50),
  avatarSimilar('Nearly identical avatar', 0.40),
  sharedGroups('Shared group memberships', 0.15);

  const MergeSignal(this.explanation, this.weight);

  final String explanation;

  /// Confidence this signal alone confers, in `[0, 1)`.
  final double weight;
}

/// A proposed merge of two handles, with its evidence.
@immutable
class MergeCandidate {
  const MergeCandidate({
    required this.a,
    required this.b,
    required this.score,
    required this.signals,
  });

  final NetworkHandle a;
  final NetworkHandle b;

  /// Combined confidence in `[0, 1]`.
  final double score;

  /// Contributing signals, strongest first.
  final List<MergeSignal> signals;

  /// True when at least one signal is strong enough to stand alone.
  bool get hasIdentitySignal => signals.any(
    (s) => s == MergeSignal.phoneExact || s == MergeSignal.emailExact,
  );

  /// Whether this pair merges without asking: a one-to-one conversation
  /// (handles only ever describe DM peers), the identical substantial name,
  /// and two *different* messengers. Nothing else auto-merges — a phone or
  /// email match still only suggests, because those can be shared devices
  /// and family addresses.
  bool get qualifiesForAutoMerge =>
      a.network != b.network && signals.contains(MergeSignal.nameExact);

  String get explanation => signals.map((s) => s.explanation).join(' · ');

  @override
  String toString() =>
      'MergeCandidate(${a.id} ~ ${b.id}, ${score.toStringAsFixed(2)}, '
      '[${signals.map((s) => s.name).join(",")}])';
}

/// Tunables for [MergeScorer]. Exposed in settings so a user who gets a bad
/// suggestion can tighten the thresholds rather than turn merging off.
@immutable
class MergeScoringConfig {
  const MergeScoringConfig({
    this.suggestThreshold = 0.55,
    this.nameSimilarityThreshold = 0.92,
    this.avatarHammingThreshold = 6,
    this.autoMergeOnIdentitySignal = false,
    this.defaultCountryCode,
  });

  /// Minimum combined score to surface a suggestion.
  final double suggestThreshold;

  /// Minimum Jaro-Winkler score for [MergeSignal.nameSimilar].
  final double nameSimilarityThreshold;

  /// Maximum avatar Hamming distance for [MergeSignal.avatarSimilar].
  final int avatarHammingThreshold;

  /// When true, [MergeCandidate.qualifiesForAutoMerge] pairs — identical
  /// substantial name, different networks, one-to-one — merge without
  /// asking. Everything else stays a suggestion.
  final bool autoMergeOnIdentitySignal;

  /// Country calling code (no `+`) used to interpret national-format numbers.
  final String? defaultCountryCode;
}

/// Scores whether two [NetworkHandle]s are the same person.
///
/// Signals combine with noisy-OR — `1 - Π(1 - wᵢ)` — rather than a sum. Two
/// weak signals reinforce each other without any combination ever exceeding
/// 1.0, and no amount of weak evidence can fake a strong identity match.
class MergeScorer {
  const MergeScorer({this.config = const MergeScoringConfig()});

  final MergeScoringConfig config;

  /// Scores one pair. Returns null when the pair is ineligible or scores below
  /// [MergeScoringConfig.suggestThreshold].
  MergeCandidate? score(
    NetworkHandle a,
    NetworkHandle b, {
    Set<String> sharedGroupRoomIds = const {},
  }) {
    if (a.id == b.id) return null;

    final signals = <MergeSignal>[];

    final phoneA = normalizePhone(
      a.phoneE164 ?? a.remoteId,
      defaultCountryCode: config.defaultCountryCode,
    );
    final phoneB = normalizePhone(
      b.phoneE164 ?? b.remoteId,
      defaultCountryCode: config.defaultCountryCode,
    );
    if (phoneA != null && phoneA == phoneB) {
      signals.add(MergeSignal.phoneExact);
    }

    final emailA = normalizeEmail(a.email);
    final emailB = normalizeEmail(b.email);
    if (emailA != null && emailA == emailB) {
      signals.add(MergeSignal.emailExact);
    }

    final nameA = a.displayName == null ? '' : normalizeName(a.displayName!);
    final nameB = b.displayName == null ? '' : normalizeName(b.displayName!);
    // Names are only evidence *across* networks: two same-network handles
    // with one name are usually two people who share it, not one person
    // twice — a bridge gives each person exactly one handle per network.
    if (a.network != b.network && nameA.isNotEmpty && nameB.isNotEmpty) {
      // A bare first name is far too common to be evidence on its own; only
      // a name with more than one part counts. And a "name" with a digit in
      // it is not a name at all — bridge ghosts wear formatted phone numbers
      // and account ids as display names, two *different* people render as
      // the same number-shaped string, and one such match poisons a contact
      // that every later merge then drags along.
      final substantial = nameA.contains(' ') || nameB.contains(' ');
      final identifierShaped =
          RegExp(r'\d').hasMatch(nameA) || RegExp(r'\d').hasMatch(nameB);
      if (substantial && !identifierShaped) {
        if (nameA == nameB) {
          signals.add(MergeSignal.nameExact);
        } else if (jaroWinkler(nameA, nameB) >=
            config.nameSimilarityThreshold) {
          signals.add(MergeSignal.nameSimilar);
        }
      }
    }

    final hashA = a.avatarDHash;
    final hashB = b.avatarDHash;
    if (hashA != null &&
        hashB != null &&
        hammingDistance64(hashA, hashB) <= config.avatarHammingThreshold) {
      signals.add(MergeSignal.avatarSimilar);
    }

    if (sharedGroupRoomIds.isNotEmpty) {
      signals.add(MergeSignal.sharedGroups);
    }

    if (signals.isEmpty) return null;

    // At least one signal must be *exact* — a name, a number or an email
    // matching to the letter. Resemblance alone (similar names, similar
    // avatars, shared groups) used to clear the score bar in combination,
    // and the result was an endless drip of look-alike pairs: merge one,
    // the next weak candidate takes its place. Soft signals still raise
    // confidence and still show as evidence; they no longer open the door.
    const exact = {
      MergeSignal.phoneExact,
      MergeSignal.emailExact,
      MergeSignal.nameExact,
    };
    if (!signals.any(exact.contains)) return null;

    var inverse = 1.0;
    for (final s in signals) {
      inverse *= 1 - s.weight;
    }
    final combined = 1 - inverse;
    if (combined < config.suggestThreshold) return null;

    signals.sort((x, y) => y.weight.compareTo(x.weight));
    return MergeCandidate(a: a, b: b, score: combined, signals: signals);
  }

  /// Scores every cross-network pair in [handles], strongest first.
  ///
  /// Pairs already merged into the same contact are skipped, as are pairs the
  /// user has explicitly rejected — [rejectedPairs] holds [pairKey] values.
  List<MergeCandidate> scoreAll(
    List<NetworkHandle> handles, {
    Set<String> rejectedPairs = const {},
    Map<String, Set<String>> sharedGroupsByPair = const {},
  }) {
    final out = <MergeCandidate>[];
    for (var i = 0; i < handles.length; i++) {
      for (var j = i + 1; j < handles.length; j++) {
        final a = handles[i];
        final b = handles[j];

        final key = pairKey(a.id, b.id);
        if (rejectedPairs.contains(key)) continue;

        // Already the same contact — nothing to propose.
        if (a.unifiedContactId != null &&
            a.unifiedContactId == b.unifiedContactId) {
          continue;
        }

        final candidate = score(
          a,
          b,
          sharedGroupRoomIds: sharedGroupsByPair[key] ?? const {},
        );
        if (candidate != null) out.add(candidate);
      }
    }
    out.sort((x, y) => y.score.compareTo(x.score));
    return out;
  }
}

/// Order-independent key for a handle pair, so a decision recorded as (a, b)
/// is still found when the pair is later considered as (b, a).
String pairKey(String handleIdA, String handleIdB) {
  return handleIdA.compareTo(handleIdB) <= 0
      ? '$handleIdA|$handleIdB'
      : '$handleIdB|$handleIdA';
}
