import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:weft_bridges/weft_bridges.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import '../../app/a11y.dart';
import '../../app/localisation.dart';
import '../components/qr_card.dart';
import 'bridge_browser_sign_in.dart';
import 'bridge_external_sign_in.dart';
import 'bridge_guides.dart';

/// Connecting an account, as one guided flow.
///
/// A bridge login is a conversation: pick how to sign in, type a phone number,
/// read back a code the network texted you, scan a QR with the phone in your
/// hand. What the protocol hands the client is a chain of declarative steps —
/// `user_input` with typed fields, `display_and_wait` with a QR payload — and
/// what the user needs is a screen that reads like the task rather than like
/// the protocol.
///
/// So this screen owns the whole journey, from "how do you want to connect" to
/// "you are connected". Everything the *bridge* decides still comes from the
/// bridge: which ways exist, the fields, their validation patterns. What is
/// decided here is how those read to someone who has never heard of a bridge:
/// [bridge_guides.dart] names the methods in plain words, says what to tap on
/// the phone while a code is on screen, and turns error codes into sentences.
/// The bridge's own words are kept for whatever the guide does not cover, and
/// under "Details" when something fails.
///
/// It does not know which door it came through. [client] is the bridge's
/// provisioning API when the server publishes it and the bot's chat when it
/// does not; both produce the same steps.
class BridgeLoginFlowScreen extends StatefulWidget {
  const BridgeLoginFlowScreen({
    super.key,
    required this.client,
    required this.network,
    this.flows,
    this.bridgeLabel,
    this.reloginId,
    this.onUseAdminRoom,
    this.browserSignIn,
    this.externalSignIn,
  });

  final BridgeLoginBackend client;
  final ChatNetwork network;

  /// The ways this bridge offers to sign in, when already known. Null asks
  /// the bridge.
  final List<BridgeLoginFlow>? flows;

  /// The bridge's own name, when it differs from the network's.
  final String? bridgeLabel;

  /// An account to sign in again rather than adding a new one.
  final String? reloginId;

  /// Opens the bot's chat, for the few things only it can do.
  final VoidCallback? onUseAdminRoom;

  /// Opens a network's sign-in page for a `cookies` step. Defaults to the
  /// in-app browser where the platform has one; tests hand in a fake.
  final BrowserSignIn? browserSignIn;

  /// Signs in to a network's single sign-on in the person's own browser, for
  /// a `cookies` step. Defaults to Mattermost's where the platform can catch
  /// the redirect; tests hand in a fake.
  final ExternalSignIn? externalSignIn;

  @override
  State<BridgeLoginFlowScreen> createState() => _BridgeLoginFlowScreenState();
}

class _BridgeLoginFlowScreenState extends State<BridgeLoginFlowScreen> {
  List<LoginMethod>? _methods;
  BridgeException? _loadError;

  /// Whether the chooser is showing: a person picks only when there is a real
  /// choice, and comes back to it from "Try another way".
  bool _choosing = false;

  LoginMethod? _method;
  BridgeLoginSession? _session;
  StreamSubscription<BridgeLoginSession>? _updates;

  final Map<String, TextEditingController> _inputs = {};

  /// Which field the user has been told about.
  ///
  /// Errors appear on submit, not on the first keystroke: a phone number is
  /// invalid for as long as it is being typed, and a field that goes red at
  /// character one is a field that shouts at someone doing nothing wrong.
  final Map<String, String> _fieldErrors = {};
  bool _submitted = false;

  /// Which step id the current inputs belong to.
  ///
  /// A two-step flow reuses this screen: the phone number's controllers must
  /// not survive into the verification code's step, or the code field arrives
  /// pre-filled with a phone number.
  String? _inputsForStep;

  /// The refresh count last announced, so each fresh QR is said once.
  int _announcedRefreshes = 0;

  /// The browser sign-ins the `cookies` step on screen offers, once asked,
  /// and which step they were asked for.
  List<ExternalSignInProvider>? _providers;
  String? _providersForStep;

  /// A browser sign-in is open; its buttons wait for it.
  bool _externalBusy = false;

  late final ExternalSignIn _defaultExternal = MattermostExternalSignIn();

  String get _networkName => widget.bridgeLabel ?? widget.network.label;

  @override
  void initState() {
    super.initState();
    final flows = widget.flows;
    if (flows != null) {
      _offer(flows);
    } else {
      unawaited(_loadFlows());
    }
  }

  @override
  void dispose() {
    unawaited(_updates?.cancel());
    final session = _session;
    if (session != null && !session.isComplete) session.cancel();
    unawaited(session?.dispose());
    for (final controller in _inputs.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _loadFlows() async {
    setState(() {
      _loadError = null;
      _methods = null;
    });
    try {
      final flows = await widget.client.loginFlows();
      if (!mounted) return;
      _offer(flows);
    } on BridgeException catch (e) {
      if (mounted) setState(() => _loadError = e);
    }
  }

  void _offer(List<BridgeLoginFlow> flows) {
    final methods = loginMethodsFor(
      widget.network,
      flows,
      withUnlisted: widget.client.acceptsUnlistedFlows,
      browser: _browser != null,
    );
    setState(() => _methods = methods);
    final everyday = methods.where((m) => !m.advanced).toList();
    // One everyday way in skips the chooser: Signal has exactly one, and
    // asking "how do you want to connect?" with one answer is a pointless
    // tap. The rarer ways stay reachable from "Try another way".
    if (methods.length == 1 || everyday.length == 1) {
      _choose(methods.length == 1 ? methods.single : everyday.single);
    } else {
      setState(() => _choosing = true);
    }
  }

  void _choose(LoginMethod method) {
    unawaited(_updates?.cancel());
    final previous = _session;
    if (previous != null && !previous.isComplete) previous.cancel();
    unawaited(previous?.dispose());

    final session = BridgeLoginSession(
      client: widget.client,
      flowId: method.flow.id,
      reloginId: widget.reloginId,
    );
    _announcedRefreshes = 0;
    _updates = session.updates.listen((_) {
      if (!mounted) return;
      setState(_syncInputsToStep);
      if (session.refreshes > _announcedRefreshes) {
        _announcedRefreshes = session.refreshes;
        announce(context, context.l10n.bridgeFlowRefreshed);
      }
    });
    setState(() {
      _method = method;
      _session = session;
      _choosing = false;
      _inputsForStep = null;
    });
    unawaited(session.start());
  }

  void _chooseAnother() {
    unawaited(_updates?.cancel());
    final session = _session;
    if (session != null && !session.isComplete) session.cancel();
    unawaited(session?.dispose());
    setState(() {
      _session = null;
      _updates = null;
      _choosing = true;
    });
  }

  bool get _hasAlternatives => (_methods?.length ?? 0) > 1;

  /// How a `cookies` step is done here, or null when it cannot be.
  ///
  /// It takes both ends: a browser on this device, and a backend that can
  /// hand the bridge what the browser collected — the provisioning API can,
  /// the bot chat cannot (it never says which cookies it wants).
  BrowserSignIn? get _browser {
    if (!widget.client.supportsCookies) return null;
    return widget.browserSignIn ??
        (browserSignInAvailable ? openBrowserSignIn : null);
  }

  /// How a `cookies` step is done in the person's own browser, or null when
  /// it cannot be. Like [_browser], it needs a backend that takes cookies.
  ExternalSignIn? get _external {
    if (!widget.client.supportsCookies) return null;
    return widget.externalSignIn ??
        (externalSignInAvailable ? _defaultExternal : null);
  }

  /// The browser sign-ins for [step], or none while they are being asked.
  List<ExternalSignInProvider> _providersFor(LoginStep step) =>
      _providersForStep == step.stepId ? _providers ?? const [] : const [];

  /// Whether [step]'s browser sign-ins are still being asked for.
  bool _askingProviders(LoginStep step) =>
      _external != null && _providersForStep != step.stepId;

  Future<void> _loadProviders(LoginStep step) async {
    final external = _external;
    final params = step.cookies;
    if (external == null || params == null) return;
    final found = await external.providers(params);
    if (!mounted || _session?.currentStep?.stepId != step.stepId) return;
    setState(() {
      _providers = found;
      _providersForStep = step.stepId;
    });
  }

  Future<void> _openExternal(
    LoginStep step,
    ExternalSignInProvider provider,
  ) async {
    final external = _external;
    final params = step.cookies;
    if (external == null || params == null || _externalBusy) return;
    setState(() => _externalBusy = true);
    try {
      final values = await external.signIn(params, provider);
      if (!mounted || values == null) return;
      unawaited(_session?.submitCookies(values));
    } on ExternalSignInException {
      if (mounted) {
        showWeftMessage(context, context.l10n.bridgeBrowserExternalFailed);
      }
    } finally {
      if (mounted) setState(() => _externalBusy = false);
    }
  }

  Future<void> _openBrowser(LoginStep step) async {
    final browser = _browser;
    final params = step.cookies;
    if (browser == null || params == null) return;
    final values = await browser(context, params, _networkName);
    if (!mounted || values == null) return;
    unawaited(_session?.submitCookies(values));
  }

  /// Drops the controllers when the step they belonged to is gone.
  void _syncInputsToStep() {
    final step = _session?.currentStep;
    if (step == null || step.stepId == _inputsForStep) return;
    for (final controller in _inputs.values) {
      controller.dispose();
    }
    _inputs.clear();
    _fieldErrors.clear();
    _submitted = false;
    _inputsForStep = step.stepId;
    _providers = null;
    _providersForStep = null;
    if (step.type == LoginStepType.cookies) unawaited(_loadProviders(step));
  }

  TextEditingController _controllerFor(LoginInputField field) =>
      _inputs.putIfAbsent(
        field.id,
        () => TextEditingController(text: field.defaultValue),
      );

  void _submit(LoginStep step) {
    setState(() {
      _submitted = true;
      _fieldErrors
        ..clear()
        ..addEntries(
          step.fields
              .where((f) => !f.validate(_inputs[f.id]?.text ?? ''))
              .map((f) => MapEntry(f.id, _messageFor(f))),
        );
    });
    if (_fieldErrors.isNotEmpty) return;

    unawaited(
      _session!.submitInput({
        for (final field in step.fields)
          field.id: _inputs[field.id]?.text.trim() ?? '',
      }),
    );
  }

  /// What to say about a field the bridge would reject.
  ///
  /// The bridge supplies a regex, not a sentence, so the sentence is this
  /// screen's job. An empty field and a malformed one are different mistakes
  /// and get different words.
  String _messageFor(LoginInputField field) {
    final l10n = context.l10n;
    final value = _inputs[field.id]?.text.trim() ?? '';
    if (value.isEmpty) return l10n.bridgeFieldRequired(field.name);
    return switch (field.type) {
      'phone_number' => l10n.bridgeFieldPhoneInvalid,
      'email' => l10n.bridgeFieldEmailInvalid,
      '2fa_code' => l10n.bridgeFieldCodeInvalid,
      _ => l10n.bridgeFieldInvalid(field.name),
    };
  }

  void _restart() {
    final method = _method;
    if (method != null) _choose(method);
  }

  void _leave(bool connected) {
    final session = _session;
    if (session != null && !session.isComplete) session.cancel();
    Navigator.of(context).pop(connected);
  }

  String get _title => widget.reloginId != null
      ? context.l10n.bridgeFlowReconnectTitle(_networkName)
      : context.l10n.botLoginTitle(_networkName);

  @override
  Widget build(BuildContext context) {
    final session = _session;
    final step = session?.currentStep;
    final methods = _methods;

    final Widget body;
    if (_loadError != null) {
      body = _Failed(
        networkName: _networkName,
        message: friendlyLoginError(
          context.l10n,
          widget.network,
          errorCode: _loadError!.errorCode,
          failure: _loadError!.failure,
        ),
        details: _loadError!.message,
        onRetry: _loadFlows,
        onClose: () => _leave(false),
      );
    } else if (methods == null) {
      body = _Working(
        label: context.l10n.bridgeFlowLoadingMethods(_networkName),
      );
    } else if (methods.isEmpty) {
      body = _Failed(
        networkName: _networkName,
        message: context.l10n.bridgeFlowNoMethods(_networkName),
        onClose: () => _leave(false),
        onUseAdminRoom: widget.onUseAdminRoom,
      );
    } else if (_choosing || session == null) {
      body = _ChooseMethod(
        network: widget.network,
        networkName: _networkName,
        methods: methods,
        onPick: _choose,
      );
    } else {
      body = switch ((session.status, step)) {
        (BridgeLoginStatus.complete, _) => _Done(
          network: widget.network,
          onClose: () => Navigator.of(context).pop(true),
        ),
        (BridgeLoginStatus.failed, _) => _Failed(
          networkName: _networkName,
          message: friendlyLoginError(
            context.l10n,
            widget.network,
            errorCode: session.errorCode,
            failure: session.failure,
            problem: session.problem,
          ),
          details: session.error,
          onRetry: _restart,
          onTryAnother: _hasAlternatives ? _chooseAnother : null,
          onClose: () => _leave(false),
        ),
        // Which buttons the step gets depends on what the server offers in
        // the browser, so it waits for that answer — a moment, and only on
        // the platforms that can open one.
        (BridgeLoginStatus.waitingForUser, final s?)
            when s.type == LoginStepType.cookies && _askingProviders(s) =>
          _Working(label: context.l10n.bridgeFlowLoadingMethods(_networkName)),
        (BridgeLoginStatus.waitingForUser, final s?)
            when s.type == LoginStepType.cookies &&
                (_browser != null || _providersFor(s).isNotEmpty) =>
          _BrowserStep(
            network: widget.network,
            networkName: _networkName,
            onOpen: _browser != null ? () => _openBrowser(s) : null,
            providers: _providersFor(s),
            onOpenExternal: (provider) => _openExternal(s, provider),
            externalBusy: _externalBusy,
            onTryAnother: _hasAlternatives ? _chooseAnother : null,
          ),
        (BridgeLoginStatus.waitingForUser, final s?)
            when s.type == LoginStepType.cookies =>
          _CookiesUnsupported(
            networkName: _networkName,
            onTryAnother: _hasAlternatives ? _chooseAnother : null,
            onUseAdminRoom: widget.onUseAdminRoom,
          ),
        (BridgeLoginStatus.waitingForUser, final s?) => _InputStep(
          step: s,
          network: widget.network,
          networkName: _networkName,
          controllerFor: _controllerFor,
          errors: _fieldErrors,
          showErrors: _submitted,
          bridgeError: session.problem == BridgeLoginProblem.invalidInput
              ? session.error
              : null,
          onChanged: () => setState(() {}),
          onSubmit: () => _submit(s),
          onTryAnother: _hasAlternatives ? _chooseAnother : null,
        ),
        (BridgeLoginStatus.waitingForRemote, final s?) => _WaitStep(
          step: s,
          network: widget.network,
          networkName: _networkName,
          flowName: _method?.flow.name ?? '',
          refreshes: session.refreshes,
          onTryAnother: _hasAlternatives ? _chooseAnother : null,
          onCancel: () => _leave(false),
        ),
        _ => _Working(label: context.l10n.bridgeFlowConnecting),
      };
    }

    return Scaffold(
      appBar: WeftAppBar(
        title: Text(_title),
        // Leaving mid-flow abandons the attempt rather than backgrounding it:
        // a half-finished login holds a slot on some bridges, and one left
        // running would fail the *next* attempt with "already in progress".
        leading: BackButton(onPressed: () => _leave(false)),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Padding(
              padding: const EdgeInsets.all(WeftSpace.xl),
              child: body,
            ),
          ),
        ),
      ),
    );
  }
}

/// Which way to sign in.
///
/// A screen rather than a sheet of list tiles, because this is a real decision
/// with real consequences: scanning a QR with the phone that holds the account
/// and typing a phone number to be texted a code are different amounts of
/// work. The easiest is marked; the technical ones wait behind a fold.
class _ChooseMethod extends StatefulWidget {
  const _ChooseMethod({
    required this.network,
    required this.networkName,
    required this.methods,
    required this.onPick,
  });

  final ChatNetwork network;
  final String networkName;
  final List<LoginMethod> methods;
  final ValueChanged<LoginMethod> onPick;

  @override
  State<_ChooseMethod> createState() => _ChooseMethodState();
}

class _ChooseMethodState extends State<_ChooseMethod> {
  bool _showAdvanced = false;

  @override
  Widget build(BuildContext context) {
    final everyday = widget.methods.where((m) => !m.advanced).toList();
    final advanced = widget.methods.where((m) => m.advanced).toList();
    // Nothing everyday at all: the advanced ones are all there is, so they
    // are not hidden behind a fold.
    final showAdvanced = _showAdvanced || everyday.isEmpty;

    return ListView(
      shrinkWrap: true,
      children: [
        _Header(
          network: widget.network,
          title: context.l10n.bridgeFlowConnectTitle(widget.networkName),
        ),
        const SizedBox(height: WeftSpace.lg),
        for (final method in everyday) ...[
          _MethodCard(
            network: widget.network,
            method: method,
            onTap: () => widget.onPick(method),
          ),
          const SizedBox(height: WeftSpace.sm),
        ],
        if (advanced.isNotEmpty && everyday.isNotEmpty)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: () => setState(() => _showAdvanced = !_showAdvanced),
              icon: Icon(
                showAdvanced
                    ? Icons.expand_less_rounded
                    : Icons.expand_more_rounded,
                size: 18,
              ),
              label: Text(context.l10n.bridgeMethodMoreOptions),
            ),
          ),
        if (showAdvanced)
          for (final method in advanced) ...[
            _MethodCard(
              network: widget.network,
              method: method,
              onTap: () => widget.onPick(method),
            ),
            const SizedBox(height: WeftSpace.sm),
          ],
      ],
    );
  }
}

class _MethodCard extends StatelessWidget {
  const _MethodCard({
    required this.network,
    required this.method,
    required this.onTap,
  });

  final ChatNetwork network;
  final LoginMethod method;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final title = methodTitle(l10n, network, method);
    final subtitle = methodSubtitle(l10n, network, method);
    return WeftFocusable(
      onTap: onTap,
      label: semanticsSentence([
        title,
        if (method.recommended) l10n.bridgeMethodRecommended,
        subtitle,
      ]),
      borderRadius: WeftRadius.allMd,
      child: Container(
        padding: const EdgeInsets.all(WeftSpace.md),
        decoration: BoxDecoration(
          color: context.colors.surfaceContainerLow,
          borderRadius: WeftRadius.allMd,
          border: Border.all(
            color: method.recommended
                ? context.colors.primary
                : context.palette.border,
            width: method.recommended ? 1.2 : 0.5,
          ),
        ),
        child: Row(
          children: [
            Icon(method.icon, size: 24, color: context.colors.primary),
            const SizedBox(width: WeftSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Wrap(
                    spacing: WeftSpace.sm,
                    runSpacing: 2,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(title, style: context.text.titleSmall),
                      if (method.recommended)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: context.colors.primaryContainer,
                            borderRadius: WeftRadius.allSm,
                          ),
                          child: Text(
                            l10n.bridgeMethodRecommended,
                            style: context.text.labelSmall?.copyWith(
                              color: context.colors.onPrimaryContainer,
                            ),
                          ),
                        ),
                    ],
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: context.text.bodySmall?.copyWith(
                        color: context.colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            WeftMirroredIcon(
              Icons.chevron_right_rounded,
              size: 20,
              color: context.colors.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

/// A step that asks the user for something.
class _InputStep extends StatelessWidget {
  const _InputStep({
    required this.step,
    required this.network,
    required this.networkName,
    required this.controllerFor,
    required this.errors,
    required this.showErrors,
    required this.onChanged,
    required this.onSubmit,
    this.bridgeError,
    this.onTryAnother,
  });

  final LoginStep step;
  final ChatNetwork network;
  final String networkName;
  final TextEditingController Function(LoginInputField) controllerFor;
  final Map<String, String> errors;
  final bool showErrors;
  final VoidCallback onChanged;
  final VoidCallback onSubmit;

  /// What the bridge said about the last value, when it refused it and kept
  /// the step open.
  final String? bridgeError;
  final VoidCallback? onTryAnother;

  /// The heading, from what is being asked for.
  String _heading(BuildContext context) {
    final l10n = context.l10n;
    if (step.fields.length == 1) {
      return switch (step.fields.single.type) {
        'phone_number' => l10n.bridgeInputPhoneHeading,
        '2fa_code' => l10n.bridgeInputCodeHeading,
        'email' => l10n.bridgeInputEmailHeading,
        'password' => l10n.bridgeInputPasswordHeading,
        'token' => l10n.bridgeInputTokenHeading,
        _ => step.fields.single.name,
      };
    }
    return l10n.bridgeInputGenericHeading(networkName);
  }

  /// Whether the bridge's instruction is saying the last try was wrong —
  /// Telegram's "Incorrect code" arrives as a fresh step whose only
  /// explanation is that line, and it deserves more than grey small print.
  bool get _isRetry => RegExp(
    'incorrect|invalid|wrong|try again',
    caseSensitive: false,
  ).hasMatch(step.instructions ?? '');

  /// The bridge's words with a capital, since they are shown as a sentence
  /// and mautrix writes its validation errors in lower case.
  static String? _sentence(String? text) {
    if (text == null || text.isEmpty) return text;
    return text[0].toUpperCase() + text.substring(1);
  }

  @override
  Widget build(BuildContext context) {
    final single = step.fields.length == 1 ? step.fields.single : null;
    final hint = single == null
        ? null
        : fieldHint(context.l10n, network, single);
    // The guide's words lead; the bridge's instruction is kept when the guide
    // has none, and promoted to a warning when it reports a failed try.
    final subtitle = _isRetry ? hint : (hint ?? step.instructions);
    final warning = _sentence(
      bridgeError ?? (_isRetry ? step.instructions : null),
    );

    return ListView(
      shrinkWrap: true,
      children: [
        _Header(network: network, title: _heading(context), subtitle: subtitle),
        if (warning != null) ...[
          const SizedBox(height: WeftSpace.md),
          _Notice(text: warning),
        ],
        const SizedBox(height: WeftSpace.lg),
        for (final field in step.fields) ...[
          if (field.isSelect)
            _SelectField(
              field: field,
              controller: controllerFor(field),
              onChanged: onChanged,
            )
          else
            _LoginField(
              field: field,
              controller: controllerFor(field),
              error: showErrors ? errors[field.id] : null,
              autofocus: field == step.fields.first,
              onChanged: onChanged,
              onSubmit: onSubmit,
            ),
          const SizedBox(height: WeftSpace.md),
        ],
        const SizedBox(height: WeftSpace.sm),
        FilledButton(
          // Always pressable: a disabled button explains nothing, and pressing
          // this one is what puts the reason under the field that is wrong.
          onPressed: onSubmit,
          child: Text(context.l10n.commonContinue),
        ),
        if (onTryAnother != null) ...[
          const SizedBox(height: WeftSpace.sm),
          TextButton(
            onPressed: onTryAnother,
            child: Text(context.l10n.bridgeFlowTryAnotherWay),
          ),
        ],
      ],
    );
  }
}

/// A bridge-supplied choice between fixed options.
class _SelectField extends StatefulWidget {
  const _SelectField({
    required this.field,
    required this.controller,
    required this.onChanged,
  });

  final LoginInputField field;
  final TextEditingController controller;
  final VoidCallback onChanged;

  @override
  State<_SelectField> createState() => _SelectFieldState();
}

class _SelectFieldState extends State<_SelectField> {
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.field.name, style: context.text.labelLarge),
        const SizedBox(height: WeftSpace.sm),
        Wrap(
          spacing: WeftSpace.sm,
          runSpacing: WeftSpace.sm,
          children: [
            for (final option in widget.field.options)
              ChoiceChip(
                label: Text(option),
                selected: widget.controller.text == option,
                onSelected: (_) {
                  setState(() => widget.controller.text = option);
                  widget.onChanged();
                },
              ),
          ],
        ),
      ],
    );
  }
}

/// One field, dressed for what it holds.
class _LoginField extends StatefulWidget {
  const _LoginField({
    required this.field,
    required this.controller,
    required this.onChanged,
    required this.onSubmit,
    this.error,
    this.autofocus = false,
  });

  final LoginInputField field;
  final TextEditingController controller;
  final VoidCallback onChanged;
  final VoidCallback onSubmit;
  final String? error;
  final bool autofocus;

  @override
  State<_LoginField> createState() => _LoginFieldState();
}

class _LoginFieldState extends State<_LoginField> {
  bool _revealed = false;

  @override
  Widget build(BuildContext context) {
    final field = widget.field;
    final isCode = field.type.contains('2fa');

    return TextField(
      controller: widget.controller,
      autofocus: widget.autofocus,
      autocorrect: false,
      enableSuggestions: false,
      obscureText: field.isSecret && !isCode && !_revealed,
      onChanged: (_) => widget.onChanged(),
      onSubmitted: (_) => widget.onSubmit(),
      textInputAction: TextInputAction.done,
      autofillHints: switch (field.type) {
        'phone_number' => const [AutofillHints.telephoneNumber],
        'email' => const [AutofillHints.email],
        'username' => const [AutofillHints.username],
        'password' => const [AutofillHints.password],
        '2fa_code' => const [AutofillHints.oneTimeCode],
        _ => null,
      },
      keyboardType: switch (field.keyboardHint) {
        'phone' => TextInputType.phone,
        'email' => TextInputType.emailAddress,
        'number' => TextInputType.number,
        'url' => TextInputType.url,
        _ => TextInputType.text,
      },
      // A verification code is read off another screen a digit at a time, so
      // it is set wide and tracked; a token is pasted and read back to check
      // it, so it is monospace.
      style: switch (field.type) {
        'token' => context.text.bodyMedium?.copyWith(fontFamily: 'monospace'),
        _ when isCode => context.text.titleMedium?.copyWith(letterSpacing: 6),
        _ => null,
      },
      inputFormatters: [
        if (field.keyboardHint == 'number')
          FilteringTextInputFormatter.digitsOnly,
      ],
      decoration: InputDecoration(
        labelText: field.name,
        hintText: field.placeholder,
        helperText: field.description,
        helperMaxLines: 3,
        errorText: widget.error,
        errorMaxLines: 3,
        suffixIcon: field.isSecret && !isCode
            ? IconButton(
                tooltip: _revealed
                    ? context.l10n.commonHide
                    : context.l10n.commonShow,
                icon: Icon(
                  _revealed
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  size: 18,
                ),
                onPressed: () => setState(() => _revealed = !_revealed),
              )
            : null,
      ),
    );
  }
}

/// A step where the user does something on the phone: scan a QR, type a
/// pairing code into WhatsApp, tap an emoji.
class _WaitStep extends StatefulWidget {
  const _WaitStep({
    required this.step,
    required this.network,
    required this.networkName,
    required this.flowName,
    required this.refreshes,
    required this.onCancel,
    this.onTryAnother,
  });

  final LoginStep step;
  final ChatNetwork network;
  final String networkName;
  final String flowName;
  final int refreshes;
  final VoidCallback onCancel;
  final VoidCallback? onTryAnother;

  @override
  State<_WaitStep> createState() => _WaitStepState();
}

class _WaitStepState extends State<_WaitStep> {
  bool _trouble = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final step = widget.step;
    final type = step.displayType ?? 'nothing';
    final data = step.displayData;
    final steps = phoneSteps(l10n, widget.network, type);

    final title = switch (type) {
      'qr' => l10n.bridgeFlowQrTitle(widget.networkName),
      'code' => l10n.bridgeFlowPairingCodeTitle(widget.networkName),
      'emoji' => l10n.bridgeFlowEmojiTitle,
      _ => step.instructions ?? l10n.bridgeFlowConfirmOnOther,
    };

    return ListView(
      shrinkWrap: true,
      children: [
        Semantics(
          header: true,
          child: Text(
            title,
            textAlign: TextAlign.center,
            style: context.text.titleMedium,
          ),
        ),
        const SizedBox(height: WeftSpace.lg),
        if (data != null && type == 'qr')
          Center(child: QrCard.data(data, size: 240, semanticsLabel: title)),
        if (data != null && type == 'code') _BigCode(code: data),
        if (data != null && type == 'emoji')
          Center(
            child: Text(
              data,
              style: const TextStyle(fontSize: 64),
              semanticsLabel: data,
            ),
          ),
        const SizedBox(height: WeftSpace.lg),
        if (steps != null)
          _PhoneSteps(steps: steps)
        else if (step.instructions != null && type != 'nothing')
          Text(
            step.instructions!,
            textAlign: TextAlign.center,
            style: context.text.bodyMedium,
          ),
        if (type == 'qr') ...[
          const SizedBox(height: WeftSpace.md),
          Text(
            widget.refreshes > 0
                ? l10n.bridgeFlowRefreshed
                : l10n.bridgeFlowRefreshes,
            textAlign: TextAlign.center,
            style: context.text.bodySmall?.copyWith(
              color: context.colors.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: WeftSpace.lg),
        // One live node over the spinner and its caption. This step ends when
        // the *other* device does something, so the user is waiting on an
        // event they cannot see coming — and every transition out of here
        // replaces the whole body.
        Semantics(
          liveRegion: true,
          container: true,
          label: l10n.bridgeFlowWaitingSemantics,
          excludeSemantics: true,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: WeftSpace.sm),
              Text(
                l10n.bridgeFlowWaiting,
                style: context.text.bodySmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        if (type == 'qr') ...[
          const SizedBox(height: WeftSpace.md),
          Center(
            child: TextButton(
              onPressed: () => setState(() => _trouble = !_trouble),
              child: Text(l10n.bridgeFlowTroubleScanning),
            ),
          ),
          if (_trouble)
            Text(
              l10n.bridgeFlowTroubleScanningBody,
              textAlign: TextAlign.center,
              style: context.text.bodySmall?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
        ],
        const SizedBox(height: WeftSpace.md),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: WeftSpace.sm,
          children: [
            if (widget.onTryAnother != null)
              TextButton(
                onPressed: widget.onTryAnother,
                child: Text(l10n.bridgeFlowTryAnotherWay),
              ),
            TextButton(
              onPressed: widget.onCancel,
              child: Text(l10n.commonCancel),
            ),
          ],
        ),
      ],
    );
  }
}

/// A pairing code to read off this screen and type into the phone.
class _BigCode extends StatelessWidget {
  const _BigCode({required this.code});

  final String code;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: WeftSpace.lg,
            vertical: WeftSpace.md,
          ),
          decoration: BoxDecoration(
            color: context.colors.surfaceContainerHigh,
            borderRadius: WeftRadius.allMd,
          ),
          child: SelectableText(
            code,
            textAlign: TextAlign.center,
            style: context.text.headlineMedium?.copyWith(
              fontFamily: 'monospace',
              letterSpacing: 4,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(height: WeftSpace.sm),
        TextButton.icon(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: code));
            showWeftMessage(context, context.l10n.bridgeFlowCodeCopied);
          },
          icon: const Icon(Icons.copy_rounded, size: 16),
          label: Text(context.l10n.bridgeFlowCopyCode),
        ),
      ],
    );
  }
}

/// What to do on the phone, as a numbered list.
class _PhoneSteps extends StatelessWidget {
  const _PhoneSteps({required this.steps});

  final List<String> steps;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(WeftSpace.md),
      decoration: BoxDecoration(
        color: context.colors.surfaceContainerLow,
        borderRadius: WeftRadius.allMd,
        border: Border.all(color: context.palette.border, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.l10n.bridgeFlowOnYourPhone,
            style: context.text.labelMedium?.copyWith(
              color: context.colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: WeftSpace.sm),
          for (final (index, line) in steps.indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: WeftSpace.xs),
              child: MergeSemantics(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 22,
                      height: 22,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: context.colors.primaryContainer,
                        shape: BoxShape.circle,
                      ),
                      // l10n-ignore: a step number, the same in every language.
                      child: Text(
                        '${index + 1}',
                        style: context.text.labelSmall?.copyWith(
                          color: context.colors.onPrimaryContainer,
                        ),
                      ),
                    ),
                    const SizedBox(width: WeftSpace.sm),
                    Expanded(child: Text(line, style: context.text.bodyMedium)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A warning line inside a step, for "that code was wrong".
class _Notice extends StatelessWidget {
  const _Notice({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.all(WeftSpace.sm),
        decoration: BoxDecoration(
          color: context.colors.errorContainer,
          borderRadius: WeftRadius.allSm,
        ),
        child: Row(
          children: [
            ExcludeSemantics(
              child: Icon(
                Icons.error_outline_rounded,
                size: 18,
                color: context.colors.onErrorContainer,
              ),
            ),
            const SizedBox(width: WeftSpace.sm),
            Expanded(
              child: Text(
                text,
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

/// A sign-in on the network's own page, before it opens.
///
/// A screen of its own rather than the page at once: a login form for
/// Instagram appearing inside another app is exactly what a person should be
/// wary of, so this says whose page it is and what Sennit does with it first.
class _BrowserStep extends StatelessWidget {
  const _BrowserStep({
    required this.network,
    required this.networkName,
    required this.onOpen,
    this.providers = const [],
    this.onOpenExternal,
    this.externalBusy = false,
    this.onTryAnother,
  });

  final ChatNetwork network;
  final String networkName;

  /// Opens the sign-in page inside Sennit; null where there is none.
  final VoidCallback? onOpen;

  /// The single sign-ons the server offers in the person's own browser.
  ///
  /// When there are any they lead: they are what most people on a company
  /// server sign in with, Google's refuses to open inside an app at all, and
  /// the browser usually remembers the person already. The page inside
  /// Sennit stays under them for a password.
  final List<ExternalSignInProvider> providers;
  final ValueChanged<ExternalSignInProvider>? onOpenExternal;
  final bool externalBusy;

  final VoidCallback? onTryAnother;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final external = providers.isNotEmpty && onOpenExternal != null;
    final onOpen = this.onOpen;
    return ListView(
      shrinkWrap: true,
      children: [
        _Header(
          network: network,
          title: l10n.bridgeMethodBrowserTitle(networkName),
          subtitle: external
              ? l10n.bridgeBrowserExternalIntro(networkName)
              : l10n.bridgeBrowserIntro(networkName),
        ),
        const SizedBox(height: WeftSpace.lg),
        if (external) ...[
          for (final provider in providers) ...[
            FilledButton.icon(
              onPressed: externalBusy ? null : () => onOpenExternal!(provider),
              icon: const Icon(Icons.open_in_browser_rounded, size: 18),
              label: Text(l10n.bridgeBrowserExternal(provider.label)),
            ),
            const SizedBox(height: WeftSpace.sm),
          ],
          if (onOpen != null)
            OutlinedButton(
              onPressed: externalBusy ? null : onOpen,
              child: Text(l10n.bridgeBrowserInApp),
            ),
        ] else if (onOpen != null)
          FilledButton.icon(
            onPressed: onOpen,
            icon: const Icon(Icons.open_in_new_rounded, size: 18),
            label: Text(l10n.bridgeBrowserContinue(networkName)),
          ),
        if (onTryAnother != null) ...[
          const SizedBox(height: WeftSpace.sm),
          TextButton(
            onPressed: onTryAnother,
            child: Text(l10n.bridgeFlowTryAnotherWay),
          ),
        ],
      ],
    );
  }
}

/// The one step type Sennit cannot render.
class _CookiesUnsupported extends StatelessWidget {
  const _CookiesUnsupported({
    required this.networkName,
    this.onTryAnother,
    this.onUseAdminRoom,
  });

  final String networkName;

  final VoidCallback? onTryAnother;
  final VoidCallback? onUseAdminRoom;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ExcludeSemantics(
          child: Icon(
            Icons.public_rounded,
            size: 40,
            color: context.colors.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: WeftSpace.lg),
        Text(
          context.l10n.bridgeFlowCookiesTitle,
          style: context.text.titleSmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: WeftSpace.sm),
        Text(
          // "Pick another way" only when there is one to pick.
          onTryAnother != null
              ? context.l10n.bridgeFlowCookiesBody
              : context.l10n.bridgeFlowCookiesOnlyWay(networkName),
          textAlign: TextAlign.center,
          style: context.text.bodySmall?.copyWith(
            color: context.colors.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: WeftSpace.lg),
        if (onTryAnother != null)
          FilledButton(
            onPressed: onTryAnother,
            child: Text(context.l10n.bridgeFlowTryAnotherWay),
          ),
        if (onUseAdminRoom != null)
          TextButton(
            onPressed: onUseAdminRoom,
            child: Text(context.l10n.bridgesAdvancedOpenChat(networkName)),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(context.l10n.commonBack),
        ),
      ],
    );
  }
}

class _Done extends StatelessWidget {
  const _Done({required this.network, required this.onClose});

  final ChatNetwork network;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    // Live, because the step before it was "waiting for something you cannot
    // see", and this is that something having happened.
    return Semantics(
      liveRegion: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ExcludeSemantics(
            child: Icon(
              Icons.check_circle_rounded,
              size: 44,
              color: context.palette.online,
            ),
          ),
          const SizedBox(height: WeftSpace.lg),
          Text(
            context.l10n.bridgeFlowConnected(network.label),
            style: context.text.titleSmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: WeftSpace.sm),
          Text(
            context.l10n.bridgeFlowConnectedBody,
            textAlign: TextAlign.center,
            style: context.text.bodySmall?.copyWith(
              color: context.colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: WeftSpace.lg),
          FilledButton(
            onPressed: onClose,
            child: Text(context.l10n.commonDone),
          ),
        ],
      ),
    );
  }
}

class _Failed extends StatefulWidget {
  const _Failed({
    required this.networkName,
    required this.message,
    required this.onClose,
    this.details,
    this.onRetry,
    this.onTryAnother,
    this.onUseAdminRoom,
  });

  final String networkName;
  final String message;

  /// The bridge's own words, kept for whoever has to work out what happened.
  final String? details;
  final VoidCallback? onRetry;
  final VoidCallback? onTryAnother;
  final VoidCallback? onUseAdminRoom;
  final VoidCallback onClose;

  @override
  State<_Failed> createState() => _FailedState();
}

class _FailedState extends State<_Failed> {
  bool _details = false;

  @override
  Widget build(BuildContext context) {
    final details = widget.details;
    return Semantics(
      liveRegion: true,
      child: ListView(
        shrinkWrap: true,
        children: [
          ExcludeSemantics(
            child: Icon(
              Icons.error_rounded,
              size: 44,
              color: context.colors.error,
            ),
          ),
          const SizedBox(height: WeftSpace.lg),
          Text(
            context.l10n.bridgeFlowFailed,
            style: context.text.titleSmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: WeftSpace.sm),
          Text(
            widget.message,
            textAlign: TextAlign.center,
            style: context.text.bodyMedium,
          ),
          if (details != null &&
              details.isNotEmpty &&
              details != widget.message) ...[
            Center(
              child: TextButton(
                onPressed: () => setState(() => _details = !_details),
                child: Text(context.l10n.bridgeFlowDetails),
              ),
            ),
            if (_details)
              SelectableText(
                details,
                textAlign: TextAlign.center,
                style: context.text.bodySmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                  fontFamily: 'monospace',
                ),
              ),
          ],
          const SizedBox(height: WeftSpace.lg),
          // Retry first, because most of what lands here is recoverable: an
          // expired QR, a mistyped code, a bridge that was restarting.
          if (widget.onRetry != null)
            FilledButton(
              onPressed: widget.onRetry,
              child: Text(context.l10n.settingsTryAgain),
            ),
          if (widget.onTryAnother != null)
            TextButton(
              onPressed: widget.onTryAnother,
              child: Text(context.l10n.bridgeFlowTryAnotherWay),
            ),
          if (widget.onUseAdminRoom != null)
            TextButton(
              onPressed: widget.onUseAdminRoom,
              child: Text(
                context.l10n.bridgesAdvancedOpenChat(widget.networkName),
              ),
            ),
          TextButton(
            onPressed: widget.onClose,
            child: Text(context.l10n.commonClose),
          ),
        ],
      ),
    );
  }
}

class _Working extends StatelessWidget {
  const _Working({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    label: label,
    excludeSemantics: true,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(height: WeftSpace.md),
        Text(
          label,
          textAlign: TextAlign.center,
          style: context.text.bodySmall?.copyWith(
            color: context.colors.onSurfaceVariant,
          ),
        ),
      ],
    ),
  );
}

/// The network's mark over a heading and a line of explanation.
class _Header extends StatelessWidget {
  const _Header({required this.network, required this.title, this.subtitle});

  final ChatNetwork network;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: Column(
        children: [
          ExcludeSemantics(child: NetworkGlyph(network: network, size: 40)),
          const SizedBox(height: WeftSpace.md),
          Semantics(
            header: true,
            child: Text(
              title,
              textAlign: TextAlign.center,
              style: context.text.titleMedium,
            ),
          ),
          if (subtitle != null && subtitle!.trim().isNotEmpty) ...[
            const SizedBox(height: WeftSpace.sm),
            Text(
              subtitle!,
              textAlign: TextAlign.center,
              style: context.text.bodySmall?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
