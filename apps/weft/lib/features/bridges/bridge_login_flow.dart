import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:weft_bridges/weft_bridges.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import '../../app/a11y.dart';
import '../../app/localisation.dart';
import '../components/qr_card.dart';

/// Connecting an account, as one guided flow.
///
/// A bridge login is a conversation: pick how to sign in, type a phone number,
/// read back a code the network texted you, scan a QR with the phone in your
/// hand. What the protocol hands the client is a chain of declarative steps —
/// `user_input` with typed fields, `display_and_wait` with a QR payload — and
/// what the user needs is a screen that reads like the task rather than like
/// the protocol.
///
/// So this screen owns the whole journey, from "which network" to "you are
/// connected", instead of the flow picker being a sheet somewhere else and the
/// steps being a bare column of text fields. Everything the *bridge* decides
/// still comes from the bridge: the fields, their names, their validation
/// patterns, the instructions. What is decided here is only how those are put
/// on screen — a phone number gets a phone keypad and a leading `+`, a
/// six-digit code gets a wide, tracked, numeric field with the caret already
/// in it, a token gets a monospace box you can paste into.
class BridgeLoginFlowScreen extends StatefulWidget {
  const BridgeLoginFlowScreen({
    super.key,
    required this.client,
    required this.network,
    required this.flows,
    this.bridgeLabel,
    this.onUseAdminRoom,
  });

  final BridgeProvisioningClient client;
  final ChatNetwork network;

  /// The ways this bridge offers to sign in. One skips the picker.
  final List<BridgeLoginFlow> flows;

  /// The bridge's own name, when it differs from the network's.
  final String? bridgeLabel;

  /// Opens the bot's management room.
  ///
  /// The escape hatch, and the reason a `cookies` step is a dead end rather
  /// than a failure: Sennit ships no embedded browser, and the admin room can
  /// do everything the provisioning API can.
  final VoidCallback? onUseAdminRoom;

  @override
  State<BridgeLoginFlowScreen> createState() => _BridgeLoginFlowScreenState();
}

class _BridgeLoginFlowScreenState extends State<BridgeLoginFlowScreen> {
  BridgeLoginFlow? _flow;
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

  @override
  void initState() {
    super.initState();
    if (widget.flows.length == 1) _choose(widget.flows.single);
  }

  @override
  void dispose() {
    _updates?.cancel();
    unawaited(_session?.dispose());
    for (final controller in _inputs.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _choose(BridgeLoginFlow flow) {
    final session = BridgeLoginSession(client: widget.client, flowId: flow.id);
    _updates = session.updates.listen((_) {
      if (!mounted) return;
      setState(() => _syncInputsToStep());
    });
    setState(() {
      _flow = flow;
      _session = session;
    });
    unawaited(session.start());
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
  }

  TextEditingController _controllerFor(LoginInputField field) =>
      _inputs.putIfAbsent(field.id, TextEditingController.new);

  /// Whether every field the bridge asked for is filled in acceptably.
  bool _isValid(LoginStep step) => step.fields.every(
    (field) => field.validate(_inputs[field.id]?.text ?? ''),
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
  /// screen's job — and "Check these fields: Phone number" underneath a form is
  /// not one. An empty field and a malformed one are different mistakes and get
  /// different words.
  String _messageFor(LoginInputField field) {
    final value = _inputs[field.id]?.text.trim() ?? '';
    if (value.isEmpty) return '${field.name} is required.';
    return switch (field.type) {
      'phone_number' =>
        'That does not look like a full phone number. Include the country '
            'code, as in +49 170 1234567.',
      'email' => 'That does not look like an email address.',
      '2fa_code' => 'That code is not the right length.',
      _ => '${field.name} is not in the format this bridge expects.',
    };
  }

  void _restart() {
    _updates?.cancel();
    unawaited(_session?.dispose());
    setState(() {
      _session = null;
      _inputsForStep = null;
    });
    final flow = _flow;
    if (flow != null) _choose(flow);
  }

  String get _title => 'Connect ${widget.bridgeLabel ?? widget.network.label}';

  @override
  Widget build(BuildContext context) {
    final session = _session;
    final step = session?.currentStep;

    return Scaffold(
      appBar: WeftAppBar(
        title: Text(_title),
        // Leaving mid-flow abandons the attempt rather than backgrounding it:
        // a half-finished login holds a slot on some bridges, and one left
        // running would fail the *next* attempt with "already in progress".
        leading: BackButton(
          onPressed: () {
            session?.cancel();
            Navigator.of(context).pop();
          },
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Padding(
              padding: const EdgeInsets.all(WeftSpace.xl),
              child: switch ((session?.status, step)) {
                (null, _) => _ChooseFlow(
                  network: widget.network,
                  flows: widget.flows,
                  onPick: _choose,
                ),
                (BridgeLoginStatus.complete, _) => _Done(
                  network: widget.network,
                  onClose: () => Navigator.of(context).pop(true),
                ),
                (BridgeLoginStatus.failed, _) => _Failed(
                  message: session!.error ?? 'Sign-in failed.',
                  onRetry: _restart,
                  onClose: () => Navigator.of(context).pop(false),
                ),
                (BridgeLoginStatus.waitingForUser, final s?)
                    when s.type == LoginStepType.cookies =>
                  _CookiesUnsupported(onUseAdminRoom: widget.onUseAdminRoom),
                (BridgeLoginStatus.waitingForUser, final s?) => _InputStep(
                  step: s,
                  network: widget.network,
                  controllerFor: _controllerFor,
                  errors: _fieldErrors,
                  showErrors: _submitted,
                  canSubmit: _isValid(s),
                  onChanged: () => setState(() {}),
                  onSubmit: () => _submit(s),
                ),
                (BridgeLoginStatus.waitingForRemote, final s?) => _WaitStep(
                  step: s,
                  flowName: _flow?.name ?? '',
                  timeout: session!.maxWait,
                  onCancel: () {
                    session.cancel();
                    Navigator.of(context).pop(false);
                  },
                ),
                _ => const _Working(),
              },
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
/// work, and the bridge's one-line description is what tells them apart.
class _ChooseFlow extends StatelessWidget {
  const _ChooseFlow({
    required this.network,
    required this.flows,
    required this.onPick,
  });

  final ChatNetwork network;
  final List<BridgeLoginFlow> flows;
  final ValueChanged<BridgeLoginFlow> onPick;

  @override
  Widget build(BuildContext context) {
    return ListView(
      shrinkWrap: true,
      children: [
        _Header(
          network: network,
          title: context.l10n.bridgeFlowChooseTitle,
          subtitle: context.l10n.bridgeFlowChooseSubtitle(network.label),
        ),
        const SizedBox(height: WeftSpace.lg),
        for (final flow in flows) ...[
          _FlowCard(flow: flow, onTap: () => onPick(flow)),
          const SizedBox(height: WeftSpace.sm),
        ],
      ],
    );
  }
}

class _FlowCard extends StatelessWidget {
  const _FlowCard({required this.flow, required this.onTap});

  final BridgeLoginFlow flow;
  final VoidCallback onTap;

  /// A guess at what the flow is, from its name.
  ///
  /// The protocol carries no icon and no category, so this reads the name the
  /// bridge chose. Wrong guesses cost a generic glyph, never a wrong action —
  /// the label beside it is the bridge's own words.
  IconData get _icon {
    final name = flow.name.toLowerCase();
    if (name.contains('qr')) return Icons.qr_code_2_rounded;
    if (name.contains('phone') || name.contains('sms')) {
      return Icons.smartphone_rounded;
    }
    if (name.contains('token') || name.contains('bot')) {
      return Icons.key_rounded;
    }
    if (name.contains('password') || name.contains('email')) {
      return Icons.alternate_email_rounded;
    }
    if (name.contains('cookie') || name.contains('browser')) {
      return Icons.public_rounded;
    }
    return Icons.login_rounded;
  }

  @override
  Widget build(BuildContext context) {
    return WeftFocusable(
      onTap: onTap,
      label: semanticsSentence([flow.name, flow.description]),
      borderRadius: WeftRadius.allMd,
      child: Container(
        padding: const EdgeInsets.all(WeftSpace.md),
        decoration: BoxDecoration(
          color: context.colors.surfaceContainerLow,
          borderRadius: WeftRadius.allMd,
          border: Border.all(color: context.palette.border, width: 0.5),
        ),
        child: Row(
          children: [
            Icon(_icon, size: 22, color: context.colors.primary),
            const SizedBox(width: WeftSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(flow.name, style: context.text.titleSmall),
                  if (flow.description != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      flow.description!,
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
    required this.controllerFor,
    required this.errors,
    required this.showErrors,
    required this.canSubmit,
    required this.onChanged,
    required this.onSubmit,
  });

  final LoginStep step;
  final ChatNetwork network;
  final TextEditingController Function(LoginInputField) controllerFor;
  final Map<String, String> errors;
  final bool showErrors;
  final bool canSubmit;
  final VoidCallback onChanged;
  final VoidCallback onSubmit;

  /// The heading, from what is being asked for.
  ///
  /// A bridge's `instructions` are prose and often absent; a step that asks for
  /// one field called "Phone number" can say so at the top of the screen
  /// without waiting for the bridge to have thought of it.
  String get _heading {
    if (step.fields.length == 1) {
      return switch (step.fields.single.type) {
        'phone_number' => 'What is your phone number?',
        '2fa_code' => 'Enter the code you were sent',
        'email' => 'What is your email address?',
        'password' => 'Enter your password',
        'token' => 'Paste your access token',
        _ => step.fields.single.name,
      };
    }
    return 'Sign in to ${network.label}';
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      shrinkWrap: true,
      children: [
        _Header(network: network, title: _heading, subtitle: step.instructions),
        const SizedBox(height: WeftSpace.lg),
        for (final field in step.fields) ...[
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
          // Enabled or not, it is pressable: a disabled button explains
          // nothing, and pressing this one is what puts the reason under the
          // field that is wrong.
          onPressed: onSubmit,
          child: Text(context.l10n.commonContinue),
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
      obscureText: field.isSecret && !_revealed,
      onChanged: (_) => widget.onChanged(),
      onSubmitted: (_) => widget.onSubmit(),
      textInputAction: TextInputAction.done,
      keyboardType: switch (field.keyboardHint) {
        'phone' => TextInputType.phone,
        'email' => TextInputType.emailAddress,
        'number' => TextInputType.number,
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
        helperText: field.description,
        helperMaxLines: 3,
        errorText: widget.error,
        errorMaxLines: 3,
        // The country code is part of the number on every network that asks
        // for one, and leaving it out is the single most common way this step
        // fails.
        prefixText: field.type == 'phone_number' ? '+' : null,
        suffixIcon: field.isSecret
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

/// A step where the user does something on another device.
class _WaitStep extends StatefulWidget {
  const _WaitStep({
    required this.step,
    required this.flowName,
    required this.timeout,
    required this.onCancel,
  });

  final LoginStep step;
  final String flowName;
  final Duration timeout;
  final VoidCallback onCancel;

  @override
  State<_WaitStep> createState() => _WaitStepState();
}

class _WaitStepState extends State<_WaitStep> {
  late DateTime _startedAt;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _restartClock();
  }

  @override
  void didUpdateWidget(_WaitStep old) {
    super.didUpdateWidget(old);
    // A refreshed payload is a new code with a full life ahead of it.
    if (old.step.displayData != widget.step.displayData) _restartClock();
  }

  void _restartClock() {
    _startedAt = DateTime.now();
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Duration get _left {
    final gone = DateTime.now().difference(_startedAt);
    final left = widget.timeout - gone;
    return left.isNegative ? Duration.zero : left;
  }

  @override
  Widget build(BuildContext context) {
    final step = widget.step;
    final minutes = _left.inMinutes;
    final seconds = _left.inSeconds % 60;

    return ListView(
      shrinkWrap: true,
      children: [
        Text(
          step.instructions ?? context.l10n.bridgeFlowConfirmOnOther,
          textAlign: TextAlign.center,
          style: context.text.titleSmall,
        ),
        const SizedBox(height: WeftSpace.lg),
        if (step.displayData != null && step.displayType == 'qr') ...[
          Center(
            child: QrCard.data(
              step.displayData!,
              semanticsLabel: context.l10n.bridgeFlowQrSemantics(
                widget.flowName,
              ),
            ),
          ),
          const SizedBox(height: WeftSpace.md),
        ],
        if (step.displayData != null) ...[
          // The raw payload stays available under the image: some networks
          // accept pasting the code, and it is the fallback if a camera has
          // trouble with a screen.
          Container(
            padding: const EdgeInsets.all(WeftSpace.md),
            decoration: BoxDecoration(
              color: context.colors.surfaceContainerHigh,
              borderRadius: WeftRadius.allMd,
            ),
            child: SelectableText(
              step.displayData!,
              textAlign: TextAlign.center,
              style: context.text.bodySmall?.copyWith(fontFamily: 'monospace'),
            ),
          ),
          const SizedBox(height: WeftSpace.sm),
          Center(
            child: TextButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: step.displayData!));
                showWeftMessage(context, context.l10n.bridgeFlowCodeCopied);
              },
              icon: const Icon(Icons.copy_rounded, size: 16),
              label: Text(context.l10n.bridgeFlowCopyCode),
            ),
          ),
          const SizedBox(height: WeftSpace.lg),
        ],
        // One live node over the spinner and its caption. This step ends when
        // the *other* device does something, so the user is waiting on an
        // event they cannot see coming — and every transition out of here
        // replaces the whole body.
        Semantics(
          liveRegion: true,
          container: true,
          label: context.l10n.bridgeFlowWaitingSemantics,
          excludeSemantics: true,
          child: Column(
            children: [
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(height: WeftSpace.md),
              Text(
                context.l10n.bridgeFlowWaiting,
                style: context.text.bodySmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: WeftSpace.xs),
              // The clock is the difference between "this is taking a while"
              // and "this has stopped working". Codes expire, and a spinner
              // that has been turning for two minutes says neither.
              Text(
                _left == Duration.zero
                    ? context.l10n.bridgeFlowExpired
                    : context.l10n.bridgeFlowExpiresIn(
                        '$minutes:${seconds.toString().padLeft(2, '0')}',
                      ),
                style: context.text.labelSmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: WeftSpace.lg),
        Center(
          child: TextButton(
            onPressed: widget.onCancel,
            child: Text(context.l10n.commonCancel),
          ),
        ),
      ],
    );
  }
}

/// The one step type Sennit cannot render.
class _CookiesUnsupported extends StatelessWidget {
  const _CookiesUnsupported({this.onUseAdminRoom});

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
          context.l10n.bridgeFlowCookiesBody,
          textAlign: TextAlign.center,
          style: context.text.bodySmall?.copyWith(
            color: context.colors.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: WeftSpace.lg),
        if (onUseAdminRoom != null)
          FilledButton.icon(
            onPressed: onUseAdminRoom,
            icon: const Icon(Icons.chat_rounded, size: 16),
            label: Text(context.l10n.bridgeFlowOpenManagementChat),
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

class _Failed extends StatelessWidget {
  const _Failed({
    required this.message,
    required this.onRetry,
    required this.onClose,
  });

  final String message;
  final VoidCallback onRetry;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
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
            message,
            textAlign: TextAlign.center,
            style: context.text.bodySmall?.copyWith(
              color: context.colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: WeftSpace.lg),
          // Retry first, because most of what lands here is recoverable: an
          // expired QR, a mistyped code, a bridge that was restarting.
          FilledButton(
            onPressed: onRetry,
            child: Text(context.l10n.settingsTryAgain),
          ),
          TextButton(onPressed: onClose, child: Text(context.l10n.commonClose)),
        ],
      ),
    );
  }
}

class _Working extends StatelessWidget {
  const _Working();

  @override
  Widget build(BuildContext context) => const Center(
    child: SizedBox(
      width: 24,
      height: 24,
      child: CircularProgressIndicator(strokeWidth: 2),
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
