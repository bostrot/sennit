import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show TextInput;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_matrix/weft_matrix.dart';
import '../../app/localisation.dart';

import '../../app/session_providers.dart';

/// Where someone new lands unless they name a server of their own.
const String kDefaultHomeserver = 'matrix.aachen.dev';

/// Sign-in: resolve a homeserver, then authenticate against it — or create
/// the account there first.
///
/// The server is validated as its own step. Telling someone their password is
/// wrong when the real problem was the server address is a bad experience, and
/// it is also how people end up believing their account is broken.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _homeserver = TextEditingController(text: kDefaultHomeserver);
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _inviteCode = TextEditingController();

  HomeserverDiscovery? _discovery;
  List<LoginFlow> _flows = const [];

  /// What the server wants from a new account; null when it could not be
  /// asked, in which case the form is offered and the server answers on
  /// submit.
  RegistrationOffer? _offer;

  /// Creating an account rather than signing in to one.
  bool _creating = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _homeserver.dispose();
    _username.dispose();
    _password.dispose();
    _confirm.dispose();
    _inviteCode.dispose();
    super.dispose();
  }

  bool get _serverResolved => _discovery != null;

  bool get _supportsPassword =>
      _flows.isEmpty || _flows.any((f) => f.type == 'm.login.password');

  bool get _supportsSso => _flows.any((f) => f.type == 'm.login.sso');

  /// Whether the create form has anything to submit to.
  bool get _canCreate =>
      _offer != RegistrationOffer.closed &&
      _offer != RegistrationOffer.unsupported;

  /// The server as the user knows it, for sentences about it.
  String get _serverName =>
      _discovery?.serverName ?? _discovery?.baseUrl.host ?? _homeserver.text;

  /// The localpart as the server will store it. Matrix localparts are
  /// lowercase, and a phone keyboard capitalises the first letter of a name.
  String get _newLocalpart => _username.text.trim().toLowerCase();

  Future<void> _resolveServer() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final session = ref.read(matrixSessionProvider);
      final discovery = await session.checkHomeserver(_homeserver.text);
      final flows = await session.supportedLoginFlows();
      // Asked now rather than on the way into the create form, so that form
      // opens already knowing whether it has an invite-code field.
      RegistrationOffer? offer;
      try {
        offer = await session.registrationOffer();
      } on Exception {
        offer = null;
      }
      if (!mounted) return;
      setState(() {
        _discovery = discovery;
        _flows = flows;
        _offer = offer;
      });
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() => _error = _humanize(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signIn() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(matrixSessionProvider)
          .loginWithPassword(
            username: _username.text.trim(),
            password: _password.text,
          );
      // A successful login is the moment the password manager should offer to
      // save what was typed; without this commit it never asks.
      TextInput.finishAutofillContext();
      // The auth gate reacts to the session state change; nothing to do here.
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() => _error = _humanize(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _createAccount() async {
    final l10n = context.l10n;
    final username = _newLocalpart;
    final String? problem;
    if (username.isEmpty || _password.text.isEmpty) {
      problem = l10n.loginErrorFieldsMissing;
    } else if (_password.text != _confirm.text) {
      problem = l10n.loginErrorPasswordMismatch;
    } else if (_offer == RegistrationOffer.needsToken &&
        _inviteCode.text.trim().isEmpty) {
      problem = l10n.loginErrorInviteMissing;
    } else {
      problem = null;
    }
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(matrixSessionProvider)
          .register(
            username: username,
            password: _password.text,
            registrationToken: _inviteCode.text,
          );
      // The moment the password manager should offer to keep the new
      // credentials — the one login nobody has anywhere else yet.
      TextInput.finishAutofillContext();
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() => _error = _humanizeRegistration(l10n, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _setCreating(bool creating) {
    setState(() {
      _creating = creating;
      _error = null;
    });
  }

  String _humanizeRegistration(AppL10n l10n, Exception e) {
    if (e is RegistrationException) {
      return switch (e.reason) {
        RegistrationFailure.closed => l10n.loginCreateClosed(_serverName),
        RegistrationFailure.unsupported => l10n.loginCreateUnsupported(
          _serverName,
        ),
        RegistrationFailure.tokenRequired => l10n.loginErrorInviteMissing,
        RegistrationFailure.tokenRejected => l10n.loginErrorInviteRejected,
      };
    }
    final text = e.toString();
    if (text.contains('M_USER_IN_USE') || text.contains('M_EXCLUSIVE')) {
      return l10n.loginErrorUsernameTaken;
    }
    if (text.contains('M_INVALID_USERNAME')) {
      return l10n.loginErrorUsernameInvalid;
    }
    if (text.contains('M_WEAK_PASSWORD') || text.contains('M_PASSWORD_')) {
      return l10n.loginErrorPasswordWeak;
    }
    return _humanize(e);
  }

  /// Turns SDK and network errors into something a person can act on.
  static String _humanize(Exception e) {
    final text = e.toString();
    if (e is FormatException) return e.message;
    if (text.contains('M_FORBIDDEN')) {
      return 'Incorrect username or password.';
    }
    if (text.contains('M_USER_DEACTIVATED')) {
      return 'That account has been deactivated.';
    }
    if (text.contains('M_LIMIT_EXCEEDED')) {
      return 'Too many attempts. Wait a moment and try again.';
    }
    if (text.contains('SocketException') ||
        text.contains('Failed host lookup')) {
      return 'Could not reach that server. Check the address and your connection.';
    }
    return 'Something went wrong. $text';
  }

  String get _primaryLabel => !_serverResolved
      ? context.l10n.commonContinue
      : _creating
      ? context.l10n.loginCreateAccount
      : context.l10n.loginSignIn;

  VoidCallback? get _primaryAction => !_serverResolved
      ? _resolveServer
      : !_creating
      ? _signIn
      : _canCreate
      ? _createAccount
      : null;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(WeftSpace.xl),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                const _Wordmark(),
                const SizedBox(height: WeftSpace.huge),

                Text(
                  context.l10n.loginServerHeading,
                  style: context.text.labelLarge,
                ),
                const SizedBox(height: WeftSpace.sm),
                // The hint is the field's whole name, and a hint is gone at the
                // first keystroke — so on a form of three fields, a reader who
                // typed into all three had three fields left called nothing.
                WeftLabelledField(
                  label: context.l10n.loginServerField,
                  child: TextField(
                    controller: _homeserver,
                    enabled: !_busy && !_serverResolved,
                    autocorrect: false,
                    keyboardType: TextInputType.url,
                    onSubmitted: (_) => _resolveServer(),
                    decoration: InputDecoration(
                      hintText: 'example.org',
                      prefixIcon: const Icon(Icons.dns_outlined, size: 20),
                      suffixIcon: _serverResolved
                          ? IconButton(
                              tooltip: context.l10n.loginChangeServer,
                              icon: const Icon(Icons.edit_outlined, size: 18),
                              onPressed: () => setState(() {
                                _discovery = null;
                                _flows = const [];
                                _offer = null;
                              }),
                            )
                          : null,
                    ),
                  ),
                ),

                if (_discovery case final d?) ...[
                  const SizedBox(height: WeftSpace.sm),
                  _ServerSummary(discovery: d),
                ],

                if (_serverResolved && !_creating && _supportsPassword) ...[
                  const SizedBox(height: WeftSpace.lg),
                  // One autofill group over both fields, with the standard
                  // hints: this is the entire contract a password manager
                  // needs to offer credentials here and to prompt to save
                  // them. Without it the fields were invisible to autofill
                  // and every login was typed by hand.
                  AutofillGroup(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        WeftLabelledField(
                          label: context.l10n.loginUsernameField,
                          child: TextField(
                            controller: _username,
                            enabled: !_busy,
                            autocorrect: false,
                            autofocus: true,
                            autofillHints: const [AutofillHints.username],
                            keyboardType: TextInputType.name,
                            decoration: InputDecoration(
                              hintText: context.l10n.loginUsernameField,
                              prefixIcon: const Icon(
                                Icons.person_outline,
                                size: 20,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: WeftSpace.sm),
                        WeftLabelledField(
                          label: context.l10n.loginPasswordField,
                          child: TextField(
                            controller: _password,
                            enabled: !_busy,
                            obscureText: true,
                            autofillHints: const [AutofillHints.password],
                            onSubmitted: (_) => _signIn(),
                            decoration: InputDecoration(
                              hintText: context.l10n.loginPasswordField,
                              prefixIcon: const Icon(
                                Icons.lock_outline,
                                size: 20,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                if (_serverResolved && _creating && !_canCreate) ...[
                  const SizedBox(height: WeftSpace.lg),
                  Text(
                    _offer == RegistrationOffer.closed
                        ? context.l10n.loginCreateClosed(_serverName)
                        : context.l10n.loginCreateUnsupported(_serverName),
                    style: context.text.bodyMedium?.copyWith(
                      color: context.colors.onSurfaceVariant,
                      height: 1.4,
                    ),
                  ),
                ],

                if (_serverResolved && _creating && _canCreate) ...[
                  const SizedBox(height: WeftSpace.lg),
                  // The `new…` hints are what tell a password manager this is
                  // a sign-up: it offers to generate a password instead of
                  // offering the ones it has for other accounts.
                  AutofillGroup(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        WeftLabelledField(
                          label: context.l10n.loginUsernameField,
                          child: TextField(
                            controller: _username,
                            enabled: !_busy,
                            autocorrect: false,
                            autofocus: true,
                            autofillHints: const [AutofillHints.newUsername],
                            keyboardType: TextInputType.name,
                            onChanged: (_) => setState(() {}),
                            decoration: InputDecoration(
                              hintText: context.l10n.loginUsernameField,
                              prefixIcon: const Icon(
                                Icons.person_outline,
                                size: 20,
                              ),
                            ),
                          ),
                        ),
                        if (_newLocalpart.isNotEmpty) ...[
                          const SizedBox(height: WeftSpace.xs),
                          // The address is what other people will type to
                          // reach this account, and the form is the last
                          // moment it can still be changed.
                          Text(
                            context.l10n.loginCreateHandle(
                              '@$_newLocalpart:$_serverName',
                            ),
                            style: context.text.bodySmall?.copyWith(
                              color: context.colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                        const SizedBox(height: WeftSpace.sm),
                        WeftLabelledField(
                          label: context.l10n.loginPasswordField,
                          child: TextField(
                            controller: _password,
                            enabled: !_busy,
                            obscureText: true,
                            autofillHints: const [AutofillHints.newPassword],
                            decoration: InputDecoration(
                              hintText: context.l10n.loginPasswordField,
                              prefixIcon: const Icon(
                                Icons.lock_outline,
                                size: 20,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: WeftSpace.sm),
                        WeftLabelledField(
                          label: context.l10n.loginConfirmPasswordField,
                          child: TextField(
                            controller: _confirm,
                            enabled: !_busy,
                            obscureText: true,
                            autofillHints: const [AutofillHints.newPassword],
                            onSubmitted: (_) => _createAccount(),
                            decoration: InputDecoration(
                              hintText: context.l10n.loginConfirmPasswordField,
                              prefixIcon: const Icon(
                                Icons.lock_outline,
                                size: 20,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_offer == RegistrationOffer.needsToken) ...[
                    const SizedBox(height: WeftSpace.sm),
                    WeftLabelledField(
                      label: context.l10n.loginInviteCodeField,
                      child: TextField(
                        controller: _inviteCode,
                        enabled: !_busy,
                        autocorrect: false,
                        enableSuggestions: false,
                        onSubmitted: (_) => _createAccount(),
                        decoration: InputDecoration(
                          hintText: context.l10n.loginInviteCodeField,
                          prefixIcon: const Icon(
                            Icons.confirmation_number_outlined,
                            size: 20,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: WeftSpace.xs),
                    Text(
                      context.l10n.loginInviteCodeHelp,
                      style: context.text.bodySmall?.copyWith(
                        color: context.colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],

                if (_error case final message?) ...[
                  const SizedBox(height: WeftSpace.lg),
                  _ErrorBanner(
                    message: message,
                    label: _creating
                        ? context.l10n.loginCreateFailed(message)
                        : context.l10n.loginFailed(message),
                  ),
                ],

                const SizedBox(height: WeftSpace.xl),
                // The spinner *replaces* the label while the request is in
                // flight, so for the seconds that matter most the button had no
                // name at all — a reader who came back to it was told only
                // "button". The label outlives the text it is made of.
                Semantics(
                  label: _busy ? context.l10n.loginWorking : _primaryLabel,
                  excludeSemantics: true,
                  button: true,
                  child: FilledButton(
                    onPressed: _busy ? null : _primaryAction,
                    child: _busy
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(_primaryLabel),
                  ),
                ),

                // The way between the two forms sits under the button of the
                // one that is showing: someone who arrived to sign up and
                // found a sign-in form looks there next.
                if (_serverResolved) ...[
                  const SizedBox(height: WeftSpace.sm),
                  TextButton(
                    onPressed: _busy ? null : () => _setCreating(!_creating),
                    child: Text(
                      _creating
                          ? context.l10n.loginSignInSwitch
                          : context.l10n.loginCreateSwitch,
                    ),
                  ),
                ],

                if (_serverResolved && !_creating && _supportsSso) ...[
                  const SizedBox(height: WeftSpace.sm),
                  OutlinedButton.icon(
                    // Completing SSO needs the deep-link callback, which lands
                    // with App Links in M8; surfacing a dead button now would
                    // be worse than saying so.
                    onPressed: null,
                    icon: const Icon(Icons.open_in_new_rounded, size: 18),
                    label: Text(context.l10n.loginSso),
                  ),
                ],

                const SizedBox(height: WeftSpace.xl),
                Text(
                  context.l10n.loginFooter,
                  textAlign: TextAlign.center,
                  style: context.text.bodySmall?.copyWith(
                    color: context.colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Wordmark extends StatelessWidget {
  const _Wordmark();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const BrandMark(size: 76),
        const SizedBox(height: WeftSpace.lg),
        Text(
          // l10n-ignore: the app's own name, never translated.
          'Braid',
          style: context.text.headlineMedium?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: -1,
          ),
        ),
        const SizedBox(height: WeftSpace.xs),
        Text(
          context.l10n.brandTagline,
          style: context.text.bodyMedium?.copyWith(
            color: context.colors.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// Shows where login will actually go — delegation surprises people, and
/// `example.org` resolving to `matrix.example.org` should be visible.
class _ServerSummary extends StatelessWidget {
  const _ServerSummary({required this.discovery});

  final HomeserverDiscovery discovery;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(WeftSpace.md),
      decoration: BoxDecoration(
        color: context.colors.surfaceContainerHigh,
        borderRadius: WeftRadius.allMd,
      ),
      child: Row(
        children: [
          Icon(
            Icons.check_circle_outline_rounded,
            size: 18,
            color: context.palette.online,
          ),
          const SizedBox(width: WeftSpace.sm),
          Expanded(
            child: Text(
              discovery.viaWellKnown
                  ? context.l10n.loginDelegatedTo(discovery.baseUrl.host)
                  : context.l10n.loginConnectedTo(discovery.baseUrl.host),
              style: context.text.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, required this.label});

  final String message;

  /// What a screen reader is told: the message, named as the failure it is.
  final String label;

  @override
  Widget build(BuildContext context) {
    // Live, and named as a failure. A sign-in that did not work leaves the user
    // on the same form with the same fields; this banner appearing above the
    // button is the entire difference, and it appears while the focus is still
    // on the button that has apparently just done nothing.
    return Semantics(
      liveRegion: true,
      container: true,
      label: label,
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.all(WeftSpace.md),
        decoration: BoxDecoration(
          color: context.colors.errorContainer,
          borderRadius: WeftRadius.allMd,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.error_outline_rounded,
              size: 18,
              color: context.colors.onErrorContainer,
            ),
            const SizedBox(width: WeftSpace.sm),
            Expanded(
              child: Text(
                message,
                style: context.text.bodySmall?.copyWith(
                  color: context.colors.onErrorContainer,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
