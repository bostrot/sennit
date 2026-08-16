import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_matrix/weft_matrix.dart';

import '../../app/session_providers.dart';

/// Sign-in: resolve a homeserver, then authenticate against it.
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
  final _homeserver = TextEditingController(text: 'matrix.org');
  final _username = TextEditingController();
  final _password = TextEditingController();

  HomeserverDiscovery? _discovery;
  List<LoginFlow> _flows = const [];
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _homeserver.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  bool get _serverResolved => _discovery != null;

  bool get _supportsPassword =>
      _flows.isEmpty || _flows.any((f) => f.type == 'm.login.password');

  bool get _supportsSso => _flows.any((f) => f.type == 'm.login.sso');

  Future<void> _resolveServer() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final session = ref.read(matrixSessionProvider);
      final discovery = await session.checkHomeserver(_homeserver.text);
      final flows = await session.supportedLoginFlows();
      if (!mounted) return;
      setState(() {
        _discovery = discovery;
        _flows = flows;
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
      // The auth gate reacts to the session state change; nothing to do here.
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() => _error = _humanize(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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

                Text('Server', style: context.text.labelLarge),
                const SizedBox(height: WeftSpace.sm),
                TextField(
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
                            tooltip: 'Change server',
                            icon: const Icon(Icons.edit_outlined, size: 18),
                            onPressed: () => setState(() {
                              _discovery = null;
                              _flows = const [];
                            }),
                          )
                        : null,
                  ),
                ),

                if (_discovery case final d?) ...[
                  const SizedBox(height: WeftSpace.sm),
                  _ServerSummary(discovery: d),
                ],

                if (_serverResolved && _supportsPassword) ...[
                  const SizedBox(height: WeftSpace.lg),
                  TextField(
                    controller: _username,
                    enabled: !_busy,
                    autocorrect: false,
                    autofocus: true,
                    decoration: const InputDecoration(
                      hintText: 'Username',
                      prefixIcon: Icon(Icons.person_outline, size: 20),
                    ),
                  ),
                  const SizedBox(height: WeftSpace.sm),
                  TextField(
                    controller: _password,
                    enabled: !_busy,
                    obscureText: true,
                    onSubmitted: (_) => _signIn(),
                    decoration: const InputDecoration(
                      hintText: 'Password',
                      prefixIcon: Icon(Icons.lock_outline, size: 20),
                    ),
                  ),
                ],

                if (_error case final message?) ...[
                  const SizedBox(height: WeftSpace.lg),
                  _ErrorBanner(message: message),
                ],

                const SizedBox(height: WeftSpace.xl),
                FilledButton(
                  onPressed: _busy
                      ? null
                      : _serverResolved
                      ? _signIn
                      : _resolveServer,
                  child: _busy
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(_serverResolved ? 'Sign in' : 'Continue'),
                ),

                if (_serverResolved && _supportsSso) ...[
                  const SizedBox(height: WeftSpace.sm),
                  OutlinedButton.icon(
                    // Completing SSO needs the deep-link callback, which lands
                    // with App Links in M8; surfacing a dead button now would
                    // be worse than saying so.
                    onPressed: null,
                    icon: const Icon(Icons.open_in_new_rounded, size: 18),
                    label: const Text('Single sign-on (M8)'),
                  ),
                ],

                const SizedBox(height: WeftSpace.xl),
                Text(
                  'Weft connects to your own Matrix server. It never proxies '
                  'your messages through anyone else.',
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
        Container(
          width: 68,
          height: 68,
          decoration: BoxDecoration(
            borderRadius: WeftRadius.allXl,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [context.colors.primary, context.colors.tertiary],
            ),
          ),
          child: Icon(
            Icons.forum_rounded,
            size: 32,
            color: context.colors.onPrimary,
          ),
        ),
        const SizedBox(height: WeftSpace.lg),
        Text(
          'Weft',
          style: context.text.headlineMedium?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: -1,
          ),
        ),
        const SizedBox(height: WeftSpace.xs),
        Text(
          'Every conversation, one thread.',
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
                  ? 'Delegated to ${discovery.baseUrl.host}'
                  : 'Connected to ${discovery.baseUrl.host}',
              style: context.text.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
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
    );
  }
}
