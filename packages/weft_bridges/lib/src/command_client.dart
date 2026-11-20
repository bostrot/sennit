import 'dart:async';

import 'backend.dart';
import 'bot_channel.dart';
import 'models.dart';

/// Which command language the bot speaks.
enum BotDialect {
  /// mautrix bridgev2 (WhatsApp, Signal, Telegram, Google Messages, Meta… from
  /// 2024 on): `login <flow>`, `list-logins`, `logout <id>`, one prompt per
  /// field.
  bridgev2,

  /// The older mautrix-go bridges that never moved to bridgev2 — Discord is
  /// the one still common: `login` shows a QR at once, `login-token` takes a
  /// token inline, `ping` reports the connection.
  legacy,
}

/// Signs in through the bridge bot's chat, as a [BridgeLoginBackend].
///
/// Every mautrix bridge has a bot that takes `login` as a chat command, and
/// that is the only door a server is guaranteed to leave open: the
/// provisioning API is often bound to the bridge's private network and never
/// published. This client types the commands a person would, and reads the
/// bot's replies back into the same [LoginStep]s the provisioning API returns —
/// so the login screen is identical whichever door it went through, and
/// nobody has to read a bot's raw replies or know what `login qr` means.
///
/// The replies it understands are the ones mautrix-go writes
/// (`bridgev2/commands/login.go` and the legacy `commands.go` of
/// mautrix-discord); anything else it does not recognise is kept as the
/// next step's instructions rather than dropped, so a bridge that words
/// something new still says it.
class BridgeCommandClient implements BridgeLoginBackend {
  BridgeCommandClient({
    required BridgeBotChannel channel,
    BotDialect? dialect,
    this.replyTimeout = const Duration(seconds: 45),
    this.waitTimeout = const Duration(minutes: 5),
    this.settle = const Duration(seconds: 3),
  }) : _channel = channel,
       _dialect = dialect;

  final BridgeBotChannel _channel;

  /// How long to wait for the bot to answer a command at all.
  final Duration replyTimeout;

  /// How long one wait on a QR or code may last before the session asks again.
  final Duration waitTimeout;

  /// How long to give the bot to follow a line of prose with the prompt or
  /// QR code it introduces.
  final Duration settle;

  BotDialect? _dialect;

  /// The QR message on screen, so an edit of it reads as a refresh.
  String? _qrEventId;

  int _prompts = 0;

  /// The legacy token flow is two-step on screen and one command on the wire:
  /// the token is asked for here, then sent with `login-token`.
  static const _legacyTokenStep = 'chat.sennit.discord.token';
  static const _qrStep = 'chat.sennit.qr';
  static const _codeStep = 'chat.sennit.code';
  static const _emojiStep = 'chat.sennit.emoji';
  static const _cookieStep = 'chat.sennit.cookies';
  static const _completeStep = 'chat.sennit.complete';

  /// Stands in for the process id the provisioning API would return; the bot
  /// keeps one login per chat, so there is nothing to address.
  static const _processId = 'chat';

  /// The flow id asked for when listing flows: an id no bridge has, which
  /// bridgev2 answers with "Invalid login flow … Available options:" and the
  /// full list — and, unlike a bare `login`, never starts one.
  static const _listFlowsProbe = 'sennit-list-flows';

  // Error codes for what only the chat says, for the app to word.
  static const errorLoginFailed = 'CHAT.SENNIT.LOGIN_FAILED';
  static const errorAlreadyLoggedIn = 'CHAT.SENNIT.ALREADY_LOGGED_IN';
  static const errorTooManyLogins = 'CHAT.SENNIT.TOO_MANY_LOGINS';
  static const errorNoPermission = 'CHAT.SENNIT.NO_PERMISSION';
  static const errorNotFound = 'CHAT.SENNIT.LOGIN_NOT_FOUND';
  static const errorNeedsBrowser = 'CHAT.SENNIT.NEEDS_BROWSER';

  final List<BotMessage> _queue = [];
  Completer<void>? _arrived;
  StreamSubscription<BotMessage>? _subscription;

  List<BridgeLogin>? _lastLogins;

  BotDialect? get dialect => _dialect;

  @override
  bool get supportsCookies => false;

  void _listen() {
    _subscription ??= _channel.messages.listen((message) {
      _queue.add(message);
      final arrived = _arrived;
      _arrived = null;
      if (arrived != null && !arrived.isCompleted) arrived.complete();
    });
  }

  /// Sends [command], first dropping anything the bot said before it.
  Future<void> _command(String command) async {
    _listen();
    await _channel.open();
    _queue.clear();
    try {
      await _channel.send(command);
    } on Exception catch (e) {
      throw BridgeException(
        'Could not send to the bridge bot: $e',
        failure: BridgeFailure.unreachable,
      );
    }
  }

  /// The bot's next message, or null after [timeout].
  Future<BotMessage?> _next(Duration timeout) async {
    if (_queue.isNotEmpty) return _queue.removeAt(0);
    final arrived = _arrived = Completer<void>();
    final timer = Timer(timeout, () {
      if (!arrived.isCompleted) arrived.complete();
    });
    await arrived.future;
    timer.cancel();
    return _queue.isEmpty ? null : _queue.removeAt(0);
  }

  /// The bot's next message that says something, skipping redactions and
  /// edits of messages other than the QR.
  Future<BotMessage?> _nextText(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) return null;
      final message = await _next(left);
      if (message == null) return null;
      if (message.isRedaction) continue;
      return message;
    }
  }

  Future<BotDialect> _detect() async {
    final known = _dialect;
    if (known != null) return known;
    await _command('list-logins');
    final reply = await _nextText(replyTimeout);
    if (reply == null) throw _noAnswer();
    final text = reply.body.trim();
    if (_unknownCommand.hasMatch(text)) return _dialect = BotDialect.legacy;
    _checkPermission(text);
    _lastLogins = _parseLogins(text);
    return _dialect = BotDialect.bridgev2;
  }

  @override
  Future<BridgeWhoami> whoami() async {
    // Looking costs nothing only while the chat exists. Opening one just to
    // ask would put a new conversation in the inbox of someone who has never
    // used this bridge — and having no chat with the bot is itself the answer
    // for a login made through it: there is none.
    if (!await _channel.exists()) return const BridgeWhoami();

    final dialect = _dialect;
    if (dialect == null) {
      await _detect();
      if (_dialect == BotDialect.bridgev2) {
        return BridgeWhoami(logins: _lastLogins ?? const []);
      }
    }

    if (_dialect == BotDialect.legacy) {
      await _command('ping');
      final reply = await _nextText(replyTimeout);
      if (reply == null) throw _noAnswer();
      return BridgeWhoami(logins: _parsePing(reply.body.trim()));
    }

    await _command('list-logins');
    final reply = await _nextText(replyTimeout);
    if (reply == null) throw _noAnswer();
    final text = reply.body.trim();
    _checkPermission(text);
    return BridgeWhoami(logins: _lastLogins = _parseLogins(text));
  }

  @override
  Future<List<BridgeLoginFlow>> loginFlows() async {
    final dialect = await _detect();
    if (dialect == BotDialect.legacy) {
      return const [
        BridgeLoginFlow(
          id: 'qr',
          name: 'QR code',
          description: 'Scan a QR code with the mobile app',
        ),
        BridgeLoginFlow(
          id: 'token',
          name: 'Token',
          description: 'Paste the token of a signed-in session',
        ),
      ];
    }

    // At the login limit a bare `login` is refused before it lists anything,
    // and a reconnect is still allowed — `relogin` with an account lists the
    // same flows.
    final existing = _lastLogins?.firstOrNull?.id;
    await _command('login $_listFlowsProbe');
    var reply = await _nextText(replyTimeout);
    if (reply == null) throw _noAnswer();
    if (_tooManyLogins.hasMatch(reply.body) && existing != null) {
      await _command('relogin $existing $_listFlowsProbe');
      reply = await _nextText(replyTimeout);
      if (reply == null) throw _noAnswer();
    }
    final text = reply.body.trim();
    _checkPermission(text);

    final flows = [
      for (final match in _flowLine.allMatches(text))
        BridgeLoginFlow(
          id: match.group(1)!,
          name: match.group(1)!,
          description: match.group(2)?.trim(),
        ),
    ];
    if (flows.isEmpty) {
      _checkError(text);
      throw BridgeException(text, errorCode: errorLoginFailed);
    }
    return flows;
  }

  @override
  Future<LoginStep> startLogin(String flowId, {String? reloginId}) async {
    final dialect = await _detect();
    _qrEventId = null;

    if (dialect == BotDialect.legacy) {
      if (flowId == 'token') {
        return LoginStep(
          stepId: _legacyTokenStep,
          type: LoginStepType.userInput,
          loginId: _processId,
          fields: const [
            LoginInputField(id: 'token', type: 'token', name: 'Token'),
          ],
        );
      }
      await _command('login');
      return _readStep();
    }

    await _command(
      reloginId == null ? 'login $flowId' : 'relogin $reloginId $flowId',
    );
    return _readStep();
  }

  @override
  Future<LoginStep> submitStep({
    required String loginId,
    required String stepId,
    required String stepType,
    Map<String, Object?>? body,
  }) async {
    if (stepType == 'cookies') {
      throw const BridgeException(
        'This sign-in needs a browser.',
        errorCode: errorNeedsBrowser,
      );
    }
    final values = body ?? const {};
    if (stepId == _legacyTokenStep) {
      await _command('login-token user ${values['token'] ?? ''}');
      return _readStep();
    }
    // One field per prompt: the bot asks for fields one at a time, and this
    // client turns each question into a step of its own.
    final value = values.values.firstOrNull?.toString() ?? '';
    await _command(value);
    return _readStep();
  }

  @override
  Future<LoginStep> waitForStep({
    required String loginId,
    required String stepId,
  }) => _readStep(timeout: waitTimeout, waiting: true);

  @override
  Future<void> cancelLogin(String loginId) async {
    try {
      await _command('cancel');
    } on BridgeException {
      // Leaving anyway.
    }
  }

  @override
  Future<void> logout(String loginId) async {
    final dialect = await _detect();
    await _command(dialect == BotDialect.legacy ? 'logout' : 'logout $loginId');
    final reply = await _nextText(replyTimeout);
    if (reply == null) throw _noAnswer();
    final text = reply.body.trim();
    if (_loginNotFound.hasMatch(text)) {
      throw BridgeException(text, errorCode: errorNotFound);
    }
    _checkPermission(text);
  }

  /// Reads the bot's replies until they amount to a step.
  ///
  /// Prose is held as the instructions of whatever comes next: bridgev2
  /// prefaces most steps with a line of its own ("Scan the QR code with the
  /// WhatsApp mobile app to log in") and then sends the step itself.
  Future<LoginStep> _readStep({Duration? timeout, bool waiting = false}) async {
    final deadline = DateTime.now().add(timeout ?? replyTimeout);
    String? prose;

    while (true) {
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) {
        final ending = prose == null ? null : _proseStep(prose);
        if (ending != null) return ending;
        if (waiting) {
          throw const BridgeException(
            'Still waiting for the other device.',
            failure: BridgeFailure.timeout,
          );
        }
        // The bot said something and then nothing: whatever it said is the
        // most useful thing to show.
        if (prose != null) {
          throw BridgeException(prose, errorCode: errorLoginFailed);
        }
        throw _noAnswer();
      }

      // Once there is prose, give the bot a moment to follow it up, then
      // decide what the prose was.
      final message = await _next(
        prose == null ? left : (settle < left ? settle : left),
      );
      if (message == null) {
        // Prose with nothing after it is an ending when it reads like one;
        // otherwise keep listening — a slow bridge may be mid-reply.
        final ending = prose == null ? null : _proseStep(prose);
        if (ending != null) return ending;
        continue;
      }

      if (message.isRedaction) {
        if (message.redacts == _qrEventId) _qrEventId = null;
        continue;
      }

      // A refreshed QR code arrives as an edit of the one on screen.
      if (message.replaces != null) {
        if (message.replaces == _qrEventId && message.body.isNotEmpty) {
          return _displayStep('qr', message.body, prose, _qrStep);
        }
        continue;
      }

      if (message.isImage) {
        _qrEventId = message.eventId;
        return _displayStep('qr', message.body.trim(), prose, _qrStep);
      }

      final text = message.body.trim();
      if (text.isEmpty) continue;

      final prompt = _prompt.firstMatch(text);
      if (prompt != null) return _inputStep(prompt, prose);

      final url = _loginUrl.firstMatch(text);
      if (url != null) {
        return LoginStep(
          stepId: _cookieStep,
          type: LoginStepType.cookies,
          loginId: _processId,
          instructions: prose,
          cookies: LoginCookiesParams(url: url.group(1)!),
        );
      }

      final code = _codeOnly.firstMatch(message.formattedBody ?? '');
      if (code != null) {
        return _displayStep(
          'code',
          _unescape(code.group(1)!),
          prose,
          _codeStep,
        );
      }

      if (_success.hasMatch(text)) return _complete(text);

      _checkPermission(text);
      _checkError(text);

      if (prose != null && _looksLikeEmoji(text) && _mentionsEmoji(prose)) {
        return _displayStep('emoji', text, prose, _emojiStep);
      }

      prose = prose == null ? text : '$prose\n$text';
    }
  }

  /// What a line of prose with nothing after it was, when it was an ending.
  LoginStep? _proseStep(String prose) {
    final last = prose.split('\n').last;
    if (_success.hasMatch(last)) return _complete(last);
    return null;
  }

  LoginStep _complete(String text) => LoginStep(
    stepId: _completeStep,
    type: LoginStepType.complete,
    loginId: _processId,
    instructions: text,
  );

  LoginStep _displayStep(
    String type,
    String data,
    String? prose,
    String stepId,
  ) => LoginStep(
    stepId: stepId,
    type: LoginStepType.displayAndWait,
    loginId: _processId,
    instructions: prose,
    displayType: type,
    displayData: data,
  );

  LoginStep _inputStep(RegExpMatch prompt, String? prose) {
    final name = prompt.group(1)!.trim();
    final rest = (prompt.group(2) ?? '').trim();
    final options = <String>[];
    final description = <String>[];
    for (final line in rest.split('\n')) {
      final optionLine = _options.firstMatch(line);
      if (optionLine != null) {
        options.addAll(
          RegExp('`([^`]+)`').allMatches(line).map((m) => m.group(1)!),
        );
      } else if (line.trim().isNotEmpty) {
        description.add(line.trim());
      }
    }
    _prompts++;
    return LoginStep(
      // A fresh id per prompt, including a repeat of the same question: the
      // screen clears its fields when the step changes, and "Incorrect code,
      // enter it again" must not arrive with the wrong code still typed in.
      stepId: 'chat.sennit.input.$_prompts',
      type: LoginStepType.userInput,
      loginId: _processId,
      instructions: prose,
      fields: [
        LoginInputField(
          id: 'value',
          type: options.isNotEmpty ? 'select' : _fieldType(name),
          name: name,
          description: description.isEmpty ? null : description.join('\n'),
          options: options,
        ),
      ],
    );
  }

  /// The field's type, from its name — the chat carries no other hint.
  static String _fieldType(String name) {
    final lower = name.toLowerCase();
    if (lower.contains('phone')) return 'phone_number';
    if (lower.contains('password') || lower.contains('pin')) return 'password';
    if (lower.contains('token') || lower.contains('json')) return 'token';
    if (lower.contains('email')) return 'email';
    if (lower.contains('code')) return '2fa_code';
    if (lower.contains('username')) return 'username';
    return 'text';
  }

  void _checkPermission(String text) {
    if (_noPermission.hasMatch(text)) {
      throw BridgeException(
        text,
        errorCode: errorNoPermission,
        failure: BridgeFailure.rejected,
      );
    }
  }

  /// Turns the bot's failure replies into exceptions with a code.
  void _checkError(String text) {
    if (_invalidValue.hasMatch(text)) {
      throw BridgeException(
        _invalidValue.firstMatch(text)!.group(1)!.trim(),
        errorCode: BridgeException.invalidInputCode,
      );
    }
    if (_alreadyLoggedIn.hasMatch(text)) {
      throw BridgeException(text, errorCode: errorAlreadyLoggedIn);
    }
    if (_tooManyLogins.hasMatch(text)) {
      throw BridgeException(text, errorCode: errorTooManyLogins);
    }
    final failed = _failure.firstMatch(text);
    if (failed != null) {
      final reason = failed.group(1)?.trim() ?? text;
      throw BridgeException(
        reason.isEmpty ? text : reason,
        errorCode: knownErrorCode(reason) ?? errorLoginFailed,
      );
    }
  }

  BridgeException _noAnswer() => const BridgeException(
    'The bridge bot did not answer.',
    failure: BridgeFailure.timeout,
  );

  /// bridgev2's `list-logins`: one line per account, `* `id` (name) - `STATE``.
  static List<BridgeLogin> _parseLogins(String text) {
    if (_notLoggedIn.hasMatch(text)) return const [];
    return [
      for (final match in _loginLine.allMatches(text))
        BridgeLogin(
          id: match.group(1)!,
          name: match.group(2)?.trim().isEmpty ?? true
              ? null
              : match.group(2)!.trim(),
          state: BridgeLoginState.fromWire(match.group(3)),
        ),
    ];
  }

  /// The legacy bridges' `ping`, which answers in a sentence.
  static List<BridgeLogin> _parsePing(String text) {
    if (_notLoggedIn.hasMatch(text)) return const [];
    final loggedIn = _pingLoggedIn.firstMatch(text);
    if (loggedIn != null) {
      return [
        BridgeLogin(
          id: loggedIn.group(2) ?? loggedIn.group(1)!,
          name: loggedIn.group(1),
          state: BridgeLoginState.connected,
        ),
      ];
    }
    if (_pingDead.hasMatch(text)) {
      return [
        BridgeLogin(
          id: 'default',
          state: BridgeLoginState.transientDisconnect,
          errorMessage: text,
        ),
      ];
    }
    if (_pingStored.hasMatch(text)) {
      return [
        BridgeLogin(
          id: 'default',
          state: BridgeLoginState.badCredentials,
          errorMessage: text,
        ),
      ];
    }
    return const [];
  }

  static bool _looksLikeEmoji(String text) =>
      text.length <= 16 && !RegExp(r'[A-Za-z0-9]').hasMatch(text);

  static bool _mentionsEmoji(String prose) =>
      prose.toLowerCase().contains('emoji');

  static String _unescape(String html) => html
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&amp;', '&');

  /// Error codes for the bridge errors whose English the chat carries, so a
  /// failure reported in the chat gets the same friendly sentence as the same
  /// failure reported by the provisioning API.
  static String? knownErrorCode(String message) {
    final lower = message.toLowerCase();
    for (final (needle, code) in _knownErrors) {
      if (lower.contains(needle)) return code;
    }
    return null;
  }

  static const _knownErrors = [
    ('entering code or scanning qr timed out', 'FI.MAU.WHATSAPP.LOGIN_TIMEOUT'),
    ('rate limited by whatsapp', 'FI.MAU.WHATSAPP.RATE_LIMITED'),
    (
      'phone number must be in international format',
      'FI.MAU.WHATSAPP.PHONE_NUMBER_NOT_INTERNATIONAL',
    ),
    ('phone number too short', 'FI.MAU.WHATSAPP.PHONE_NUMBER_TOO_SHORT'),
    ("qr code wasn't scanned in time", 'FI.MAU.BRIDGE.LOGIN_TIMED_OUT'),
    ('maximum number of linked devices', 'FI.MAU.SIGNAL.DEVICE_LIMIT_REACHED'),
    ('invalid or already used', 'FI.MAU.SIGNAL.DEVICE_LINK_CODE_INVALID'),
    ('rate-limited the linking', 'FI.MAU.SIGNAL.DEVICE_LINK_RATE_LIMITED'),
    ('phone_code_invalid', 'FI.MAU.TELEGRAM.PHONE_CODE_INVALID'),
    ('phone_code_expired', 'FI.MAU.TELEGRAM.PHONE_CODE_EXPIRED'),
    ('phone_number_invalid', 'FI.MAU.TELEGRAM.PHONE_NUMBER_INVALID'),
    ('flood_wait', 'FI.MAU.TELEGRAM.FLOOD_WAIT'),
    ('captcha', 'CHAT.SENNIT.CAPTCHA'),
    ('timed out', 'FI.MAU.BRIDGE.LOGIN_TIMED_OUT'),
  ];

  static final _unknownCommand = RegExp(r'^Unknown command', multiLine: true);
  static final _notLoggedIn = RegExp(
    r"You're not logged in|You are not logged in",
    caseSensitive: false,
  );
  static final _noPermission = RegExp(
    r"(don't|do not) have permission|requires login permission|"
    r'not allowed to|You are not whitelisted',
    caseSensitive: false,
  );
  static final _loginLine = RegExp(
    r'^\s*[*-]\s*`([^`]+)`\s*\(([^)]*)\)\s*-\s*`([^`]*)`',
    multiLine: true,
  );
  static final _flowLine = RegExp(
    r'^\s*[*-]\s*`([^`]+)`\s*(?:-\s*(.*))?$',
    multiLine: true,
  );
  static final _prompt = RegExp(
    r'^Please enter your ([^\n]+)(?:\n([\s\S]*))?$',
  );
  static final _options = RegExp(r'^\s*Options:');
  static final _loginUrl = RegExp(r'^Login URL:\s*<?([^>\s]+)>?');
  static final _codeOnly = RegExp(r'^\s*<code>([^<]+)</code>\s*$');
  static final _success = RegExp(
    r'^(Successfully (logged in|re-?authenticated)|Logged in as |Login successful)',
    caseSensitive: false,
  );
  static final _invalidValue = RegExp(r'^Invalid value(?: for [^:]+)?:\s*(.*)');
  static final _alreadyLoggedIn = RegExp(
    r"You're already logged in|You are already logged in",
    caseSensitive: false,
  );
  static final _tooManyLogins = RegExp(
    'reached the maximum number of logins',
    caseSensitive: false,
  );
  static final _loginNotFound = RegExp(r'^Login `[^`]*` not found');
  static final _failure = RegExp(
    r'^(?:Login failed|Failed to (?:prepare login process|start login|submit input|send QR code|encode QR code|upload QR code)|'
    r'Error logging in|Error connecting(?: to Discord| to login websocket| after login)?|'
    r'Invalid login flow[^.]*|Invalid token|Login `[^`]*` not found|Unsupported display type)'
    r'[:.]?\s*([\s\S]*)$',
  );
  static final _pingLoggedIn = RegExp(
    r"You're logged in as @?(\S+)(?:\s*\(`([^`]+)`\))?",
  );
  static final _pingDead = RegExp('connection seems to be dead');
  static final _pingStored = RegExp('token stored, but are not connected');

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    _subscription = null;
    final arrived = _arrived;
    _arrived = null;
    if (arrived != null && !arrived.isCompleted) arrived.complete();
    unawaited(_channel.close());
  }
}
