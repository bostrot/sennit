import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matrix/matrix.dart' show MatrixException;
import 'package:url_launcher/url_launcher.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_matrix/weft_matrix.dart';

import '../../app/a11y.dart';
import '../../app/billing_providers.dart';
import '../../app/localisation.dart';
import '../../services/account/account_deletion.dart';
import 'settings_section.dart';

/// The server half of a Matrix ID: `matrix.org` in `@alice:matrix.org`.
String serverOfUserId(String userId) {
  final colon = userId.indexOf(':');
  return colon < 0 ? userId : userId.substring(colon + 1);
}

/// The username half of a Matrix ID: `alice` in `@alice:matrix.org`.
String localpartOfUserId(String userId) {
  final colon = userId.indexOf(':');
  final start = userId.startsWith('@') ? 1 : 0;
  return userId.substring(start, colon < 0 ? userId.length : colon);
}

/// Deleting the account, said in full before it is done.
///
/// The App Store and Google Play both require that an account an app lets
/// people create can be deleted from inside the app, and the requirement is the
/// floor rather than the design. The design is the list: every consequence in
/// a sentence of its own, including the two people get wrong — that the people
/// they wrote to keep their copies, and that a purchase is not this account's
/// to refund — so nothing about it is a surprise afterwards.
///
/// The username has to be typed before the button unlocks. A dialog's "Are you
/// sure?" is a tap away from muscle memory; typing a name is not.
class DeleteAccountScreen extends ConsumerStatefulWidget {
  const DeleteAccountScreen({super.key});

  @override
  ConsumerState<DeleteAccountScreen> createState() =>
      _DeleteAccountScreenState();
}

enum _Step { idle, bridges, account }

class _DeleteAccountScreenState extends ConsumerState<DeleteAccountScreen> {
  final _confirmation = TextEditingController();
  _Step _step = _Step.idle;

  @override
  void initState() {
    super.initState();
    _confirmation.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _confirmation.dispose();
    super.dispose();
  }

  void _setStep(_Step step) {
    setState(() => _step = step);
    final line = switch (step) {
      _Step.idle => null,
      _Step.bridges => context.l10n.deleteAccountStepBridges,
      _Step.account => context.l10n.deleteAccountStepAccount,
    };
    if (line != null) announce(context, line);
  }

  Future<void> _delete(String userId) async {
    final l10n = context.l10n;
    final server = serverOfUserId(userId);
    final deletion = ref.read(accountDeletionProvider);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final navigator = Navigator.of(context);
    var bridgesSignedOut = false;

    try {
      _setStep(_Step.bridges);
      final report = await deletion.signOutBridges();
      if (!mounted) return;
      bridgesSignedOut = report.signedOut > 0;
      if (report.failed.isNotEmpty &&
          !await _confirmDespiteBridges(report.failed)) {
        _finish(
          bridgesSignedOut
              ? l10n.deleteAccountCancelledAfterBridges
              : l10n.deleteAccountCancelled,
        );
        return;
      }
      if (!mounted) return;

      _setStep(_Step.account);
      await deletion.deleteAccount(_Reauth(this, userId: userId));

      // The account is gone and the session with it; the auth gate is already
      // drawing the welcome screen underneath every route pushed over it.
      navigator.popUntil((route) => route.isFirst);
      // A snack bar is a live region, so this is read out as well as shown —
      // on the welcome screen, since this one is gone.
      messenger?.showSnackBar(SnackBar(content: Text(l10n.deleteAccountDone)));
    } on AccountDeactivationCancelled {
      _finish(
        bridgesSignedOut
            ? l10n.deleteAccountCancelledAfterBridges
            : l10n.deleteAccountCancelled,
      );
    } on AccountDeactivationUnsupported {
      _finish(l10n.deleteAccountUnsupported(server));
    } catch (error) {
      _finish(l10n.deleteAccountFailed(_describe(error)));
    }
  }

  /// Back to the form, with a sentence saying how far it got.
  void _finish(String message) {
    if (!mounted) return;
    setState(() => _step = _Step.idle);
    showWeftMessage(context, message);
  }

  static String _describe(Object error) => switch (error) {
    MatrixException(:final errorMessage) => errorMessage,
    _ => '$error',
  };

  Future<bool> _confirmDespiteBridges(List<String> networks) async {
    final answer = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.deleteAccountBridgesFailedTitle),
        content: Text(
          context.l10n.deleteAccountBridgesFailedBody(networks.join(', ')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.l10n.commonCancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: context.colors.error,
              foregroundColor: context.colors.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.l10n.deleteAccountAnyway),
          ),
        ],
      ),
    );
    return answer ?? false;
  }

  Future<String?> _askPassword(String userId, {required bool retry}) {
    final l10n = context.l10n;
    final message = l10n.deleteAccountPasswordMessage(userId);
    return showDialog<String>(
      context: context,
      builder: (_) => TextPromptDialog(
        title: l10n.deleteAccountPasswordTitle,
        message: message,
        // Under the field, where the eye already is after a refused password.
        helperText: retry ? l10n.deleteAccountPasswordRetry : null,
        fieldLabel: l10n.deleteAccountPasswordField,
        confirmLabel: l10n.deleteAccountButton,
        obscure: true,
      ),
    );
  }

  Future<bool> _completeInBrowser(Uri url, String userId) async {
    final opened = await launchUrl(url, mode: LaunchMode.externalApplication);
    if (!opened || !mounted) return false;
    final answer = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.deleteAccountBrowserTitle),
        content: Text(
          context.l10n.deleteAccountBrowserBody(serverOfUserId(userId)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.l10n.deleteAccountBrowserDone),
          ),
        ],
      ),
    );
    return answer ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final userId = ref.watch(ownUserIdProvider);
    final charges = ref.watch(proControllerProvider).charges;

    return Scaffold(
      appBar: WeftAppBar(title: Text(l10n.deleteAccountTitle)),
      body: WeftReadingPane(
        child: userId == null
            ? const SizedBox.shrink()
            : _form(context, userId, charges: charges),
      ),
    );
  }

  Widget _form(BuildContext context, String userId, {required bool charges}) {
    final l10n = context.l10n;
    final server = serverOfUserId(userId);
    final localpart = localpartOfUserId(userId);
    final busy = _step != _Step.idle;
    final confirmed = _confirmation.text.trim() == localpart;

    return ListView(
      padding: const EdgeInsets.all(WeftSpace.lg),
      children: [
        Text(l10n.deleteAccountLead(userId), style: context.text.titleMedium),
        const SizedBox(height: WeftSpace.md),
        for (final (icon, line) in [
          (
            Icons.person_off_outlined,
            l10n.deleteAccountPointDeactivated(server),
          ),
          (
            Icons.cleaning_services_outlined,
            l10n.deleteAccountPointErased(server),
          ),
          (Icons.link_off_rounded, l10n.deleteAccountPointBridges),
          (Icons.forum_outlined, l10n.deleteAccountPointCopies),
          (Icons.phonelink_erase_rounded, l10n.deleteAccountPointDevice),
          if (charges)
            (Icons.workspace_premium_outlined, l10n.deleteAccountPointPro),
        ])
          _Consequence(icon: icon, text: line),
        const SizedBox(height: WeftSpace.lg),
        // Drawn as well as announced: the hint that repeats the username is
        // gone with the first character typed. The field says the same words to
        // a screen reader on its own node, so this copy is kept out of the way.
        ExcludeSemantics(
          child: Text(
            l10n.deleteAccountConfirmField(localpart),
            style: context.text.labelLarge,
          ),
        ),
        const SizedBox(height: WeftSpace.sm),
        WeftLabelledField(
          label: l10n.deleteAccountConfirmField(localpart),
          child: TextField(
            controller: _confirmation,
            enabled: !busy,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(hintText: localpart),
          ),
        ),
        const SizedBox(height: WeftSpace.lg),
        if (busy) ...[
          const LinearProgressIndicator(),
          const SizedBox(height: WeftSpace.sm),
          Text(
            _step == _Step.bridges
                ? l10n.deleteAccountStepBridges
                : l10n.deleteAccountStepAccount,
            style: context.text.bodyMedium,
          ),
        ] else
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FilledButton.icon(
              icon: const Icon(Icons.delete_forever_rounded),
              label: Text(l10n.deleteAccountButton),
              style: FilledButton.styleFrom(
                backgroundColor: context.colors.error,
                foregroundColor: context.colors.onError,
              ),
              onPressed: confirmed ? () => _delete(userId) : null,
            ),
          ),
      ],
    );
  }
}

/// One consequence, with an icon a sighted reader can scan by and a screen
/// reader skips.
class _Consequence extends StatelessWidget {
  const _Consequence({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: WeftSpace.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(
            child: Icon(icon, size: 20, color: context.colors.error),
          ),
          const SizedBox(width: WeftSpace.md),
          Expanded(child: Text(text, style: context.text.bodyMedium)),
        ],
      ),
    );
  }
}

/// The screen's prompts, as the deactivation asks for them.
class _Reauth implements AccountReauth {
  _Reauth(this._screen, {required this.userId});

  final _DeleteAccountScreenState _screen;
  final String userId;

  @override
  Future<String?> password({bool retry = false}) async {
    if (!_screen.mounted) return null;
    return _screen._askPassword(userId, retry: retry);
  }

  @override
  Future<bool> completeInBrowser(Uri url) async {
    if (!_screen.mounted) return false;
    return _screen._completeInBrowser(url, userId);
  }
}
