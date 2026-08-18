import 'package:flutter/material.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_sms/weft_sms.dart';

/// What sending this text over SMS actually means, above the composer.
///
/// Two facts, and both of them are things the rest of Weft's inbox lets a user
/// stop thinking about:
///
/// - **It is not encrypted.** Every other network in the inbox arrives over an
///   E2EE Matrix room. SMS is plaintext across the air interface, sits readable
///   in the carrier's logs, and Weft has no way to change that. A composer that
///   looked identical to the encrypted one would be the app telling a lie by
///   omission, and this is the single most important thing on this bar.
/// - **It costs.** GSM-7 gives 160 characters, one curly quote pasted from a
///   word processor drops that to 70, and nothing on the keyboard says so. The
///   count is shown from the first character rather than appearing near a
///   boundary, because a user who is told "3 messages" only once they have
///   written three has already been charged for the surprise.
///
/// The plan comes from [segmentMessage], never from an ASCII check here: the
/// GSM-7 table is narrower than it looks — `à` is in it and `á` is not — so a
/// guess at the call site is wrong for exactly the characters that cost money.
class SmsComposerBar extends StatelessWidget {
  const SmsComposerBar({super.key, required this.body});

  /// The text currently in the composer.
  final String body;

  @override
  Widget build(BuildContext context) {
    final plan = segmentMessage(body);
    final accent = context.palette.networkColor(ChatNetwork.sms);
    final muted = context.colors.onSurfaceVariant;

    return Padding(
      padding: const EdgeInsets.only(bottom: WeftSpace.xs),
      child: Row(
        children: [
          Icon(Icons.lock_open_rounded, size: 14, color: accent),
          const SizedBox(width: WeftSpace.xs),
          Text(
            'Not encrypted',
            style: context.text.labelSmall?.copyWith(
              color: accent,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          Text(
            _cost(plan),
            style: context.text.labelSmall?.copyWith(
              // The count only turns the network's colour once it has become a
              // charge the user did not expect. Colouring it from the first
              // character would make the warning invisible by being constant.
              color: plan.isMultipart ? accent : muted,
              fontWeight: plan.isMultipart ? FontWeight.w600 : null,
            ),
          ),
        ],
      ),
    );
  }

  /// The segment count in words a bill would use.
  ///
  /// The encoding is named only when it is the *reason* for the count — a
  /// single GSM-7 segment needs no explanation, whereas "2 messages · UCS-2"
  /// tells someone who pasted a curly quote what to look for.
  static String _cost(SegmentPlan plan) {
    final unicode = plan.isUnicode ? ' · ${plan.encoding.label}' : '';
    if (!plan.isMultipart) {
      return '${plan.remainingInLastSegment} left$unicode';
    }
    return '${plan.segments} messages$unicode';
  }
}
