import 'dart:async';

import 'package:test/test.dart';
import 'package:weft_bridges/weft_bridges.dart';

/// A bridge bot that answers commands with what mautrix-go writes.
///
/// The replies are copied from `bridgev2/commands/login.go` (and the legacy
/// `commands.go` of mautrix-discord), so what is asserted is that a real bot's
/// words become the right steps — not that a stub agrees with itself.
class _FakeBot implements BridgeBotChannel {
  _FakeBot(this.reply, {this.existing = true});

  /// What the bot says back to a command, in order.
  final List<BotMessage> Function(String command, _FakeBot bot) reply;

  bool existing;
  bool opened = false;
  final List<String> sent = [];
  final _messages = StreamController<BotMessage>.broadcast();
  int _ids = 0;

  String nextId() => '\$e${_ids++}';

  /// Says something unprompted, the way the bot follows up a QR scan.
  void say(List<BotMessage> messages) {
    for (final message in messages) {
      _messages.add(message);
    }
  }

  @override
  Future<bool> exists() async => existing;

  @override
  Future<void> open() async {
    opened = true;
    existing = true;
  }

  @override
  Future<void> send(String text) async {
    sent.add(text);
    final answers = reply(text, this);
    // Asynchronously, as a homeserver would deliver them.
    scheduleMicrotask(() => say(answers));
  }

  @override
  Stream<BotMessage> get messages => _messages.stream;

  @override
  Future<void> close() => _messages.close();
}

BotMessage _text(_FakeBot bot, String body, {String? html}) =>
    BotMessage(eventId: bot.nextId(), body: body, formattedBody: html);

BotMessage _image(_FakeBot bot, String data, {String? replaces}) => BotMessage(
  eventId: bot.nextId(),
  body: data,
  isImage: true,
  replaces: replaces,
);

BridgeCommandClient _client(_FakeBot bot) => BridgeCommandClient(
  channel: bot,
  replyTimeout: const Duration(milliseconds: 300),
  waitTimeout: const Duration(milliseconds: 300),
  settle: const Duration(milliseconds: 30),
);

void main() {
  group('dialect and status', () {
    test('looking at status never opens a chat that does not exist', () async {
      final bot = _FakeBot((_, _) => const [], existing: false);
      final client = _client(bot);
      addTearDown(client.dispose);

      final whoami = await client.whoami();

      expect(whoami.logins, isEmpty);
      expect(bot.opened, isFalse);
      expect(bot.sent, isEmpty);
    });

    test('bridgev2 list-logins becomes accounts with their state', () async {
      final bot = _FakeBot(
        (command, bot) => [
          if (command == 'list-logins')
            _text(
              bot,
              '\n\n* `4915112345678` (+4915112345678) - `CONNECTED`\n'
              '* `4917000000000` (+4917000000000) - `BAD_CREDENTIALS`',
            ),
        ],
      );
      final client = _client(bot);
      addTearDown(client.dispose);

      final whoami = await client.whoami();

      expect(client.dialect, BotDialect.bridgev2);
      expect(whoami.logins.map((l) => l.id), [
        '4915112345678',
        '4917000000000',
      ]);
      expect(whoami.logins.first.state, BridgeLoginState.connected);
      expect(whoami.logins.last.state, BridgeLoginState.badCredentials);
    });

    test('"Unknown command" marks a legacy bot, asked with ping', () async {
      final bot = _FakeBot(
        (command, bot) => [
          if (command == 'list-logins')
            _text(bot, 'Unknown command, use the `help` command for help.'),
          if (command == 'ping')
            _text(bot, "You're logged in as @anna (`123456789`)"),
        ],
      );
      final client = _client(bot);
      addTearDown(client.dispose);

      final whoami = await client.whoami();

      expect(client.dialect, BotDialect.legacy);
      expect(whoami.logins.single.label, 'anna');
      expect(whoami.logins.single.state, BridgeLoginState.connected);
    });

    test('a bot that never answers is a timeout, not a hang', () async {
      final bot = _FakeBot((_, _) => const []);
      final client = _client(bot);
      addTearDown(client.dispose);

      await expectLater(
        client.whoami(),
        throwsA(
          isA<BridgeException>().having(
            (e) => e.failure,
            'failure',
            BridgeFailure.timeout,
          ),
        ),
      );
    });
  });

  group('flows', () {
    test('listed without starting one', () async {
      final bot = _FakeBot(
        (command, bot) => [
          if (command == 'list-logins') _text(bot, "You're not logged in"),
          if (command.startsWith('login '))
            _text(
              bot,
              'Invalid login flow `sennit-list-flows`. Available options:\n\n'
              '* `qr` - Scan a QR code to pair the bridge to your WhatsApp account\n'
              '* `phone` - Input your phone number to get a pairing code, to '
              'pair the bridge to your WhatsApp account\n',
            ),
        ],
      );
      final client = _client(bot);
      addTearDown(client.dispose);

      final flows = await client.loginFlows();

      expect(flows.map((f) => f.id), ['qr', 'phone']);
      expect(flows.first.description, startsWith('Scan a QR code'));
      expect(bot.sent, ['list-logins', 'login sennit-list-flows']);
    });

    test('at the login limit, listed through relogin', () async {
      final bot = _FakeBot(
        (command, bot) => [
          if (command == 'list-logins')
            _text(bot, '* `111` (Anna) - `BAD_CREDENTIALS`'),
          if (command == 'login sennit-list-flows')
            _text(
              bot,
              'You have reached the maximum number of logins (1). Please '
              'logout from an existing login before creating a new one.',
            ),
          if (command == 'relogin 111 sennit-list-flows')
            _text(
              bot,
              'Invalid login flow `sennit-list-flows`. Available options:\n\n'
              '* `qr` - Scan a QR code to pair the bridge to your Signal app\n',
            ),
        ],
      );
      final client = _client(bot);
      addTearDown(client.dispose);

      expect((await client.loginFlows()).single.id, 'qr');
    });

    test('a legacy bot offers QR and token', () async {
      final bot = _FakeBot(
        (command, bot) => [
          _text(bot, 'Unknown command, use the `help` command for help.'),
        ],
      );
      final client = _client(bot);
      addTearDown(client.dispose);

      expect((await client.loginFlows()).map((f) => f.id), ['qr', 'token']);
    });
  });

  group('WhatsApp QR through the chat', () {
    test('QR, two refreshes by edit, scan, success', () async {
      late String qrEvent;
      final bot = _FakeBot((command, bot) {
        if (command == 'list-logins') {
          return [_text(bot, "You're not logged in")];
        }
        if (command == 'login qr') {
          final image = _image(bot, '2@first');
          qrEvent = image.eventId;
          return [
            _text(
              bot,
              'Scan the QR code with the WhatsApp mobile app to log in',
            ),
            image,
          ];
        }
        return const [];
      });
      final client = _client(bot);
      addTearDown(client.dispose);

      final session = BridgeLoginSession(
        client: client,
        flowId: 'qr',
        pollInterval: const Duration(milliseconds: 10),
      );
      addTearDown(session.dispose);
      final shown = <String>[];
      session.updates.listen((s) {
        final data = s.currentStep?.displayData;
        if (data != null && (shown.isEmpty || shown.last != data)) {
          shown.add(data);
        }
      });

      final done = session.start();
      await _until(() => session.status == BridgeLoginStatus.waitingForRemote);
      expect(session.currentStep!.displayType, 'qr');
      expect(
        session.currentStep!.instructions,
        'Scan the QR code with the WhatsApp mobile app to log in',
      );

      bot.say([_image(bot, '2@second', replaces: qrEvent)]);
      await _until(() => shown.length == 2);
      bot.say([_image(bot, '2@third', replaces: qrEvent)]);
      await _until(() => shown.length == 3);
      bot.say([
        BotMessage(eventId: bot.nextId(), redacts: qrEvent),
        _text(bot, 'Successfully logged in as +4915112345678'),
      ]);
      await done;

      expect(shown, ['2@first', '2@second', '2@third']);
      expect(session.status, BridgeLoginStatus.complete);
      expect(session.refreshes, 2);
    });

    test('the QR expiring is a timeout error with WhatsApp\'s code', () async {
      final bot = _FakeBot((command, bot) {
        if (command == 'list-logins') {
          return [_text(bot, "You're not logged in")];
        }
        if (command == 'login qr') return [_image(bot, '2@first')];
        return const [];
      });
      final client = _client(bot);
      addTearDown(client.dispose);
      final session = BridgeLoginSession(client: client, flowId: 'qr');
      addTearDown(session.dispose);

      final done = session.start();
      await _until(() => session.status == BridgeLoginStatus.waitingForRemote);
      bot.say([
        _text(
          bot,
          'Login failed: Entering code or scanning QR timed out. Please try again.',
        ),
      ]);
      await done;

      expect(session.status, BridgeLoginStatus.failed);
      expect(session.errorCode, 'FI.MAU.WHATSAPP.LOGIN_TIMEOUT');
    });
  });

  group('WhatsApp pairing code through the chat', () {
    test('phone prompt, code display, success', () async {
      final bot = _FakeBot((command, bot) {
        if (command == 'list-logins') {
          return [_text(bot, "You're not logged in")];
        }
        if (command == 'login phone') {
          return [
            _text(
              bot,
              'Please enter your Phone number\nInclude the country code with +',
            ),
          ];
        }
        if (command == '+4915112345678') {
          return [
            _text(
              bot,
              'Input the pairing code in the WhatsApp mobile app to log in',
            ),
            _text(bot, 'ABCD-EFGH', html: '<code>ABCD-EFGH</code>'),
          ];
        }
        return const [];
      });
      final client = _client(bot);
      addTearDown(client.dispose);
      final session = BridgeLoginSession(client: client, flowId: 'phone');
      addTearDown(session.dispose);

      await session.start();
      final field = session.currentStep!.fields.single;
      expect(field.type, 'phone_number');
      expect(field.name, 'Phone number');
      expect(field.description, 'Include the country code with +');

      final done = session.submitInput({field.id: '+49 151 12345678'});
      await _until(() => session.status == BridgeLoginStatus.waitingForRemote);
      expect(session.currentStep!.displayType, 'code');
      expect(session.currentStep!.displayData, 'ABCD-EFGH');
      expect(bot.sent.last, '+4915112345678');

      bot.say([_text(bot, 'Successfully logged in as +4915112345678')]);
      await done;
      expect(session.status, BridgeLoginStatus.complete);
    });
  });

  group('Telegram through the chat', () {
    test('phone, wrong code, right code, 2FA password', () async {
      var codeTries = 0;
      final bot = _FakeBot((command, bot) {
        switch (command) {
          case 'list-logins':
            return [_text(bot, "You're not logged in")];
          case 'login phone':
            return [_text(bot, 'Please enter your Phone number')];
          case '+4915112345678':
            return [
              _text(bot, 'Enter the login code Telegram sent you'),
              _text(bot, 'Please enter your Code'),
            ];
          case '11111' || '22222':
            codeTries++;
            if (codeTries == 1) {
              return [
                _text(bot, 'Incorrect code'),
                _text(bot, 'Please enter your Code'),
              ];
            }
            return [
              _text(bot, 'You have two-factor authentication enabled.'),
              _text(bot, 'Please enter your Password'),
            ];
          case 'hunter2':
            return [_text(bot, 'Successfully logged in as Anna (`777`)')];
        }
        return const [];
      });
      final client = _client(bot);
      addTearDown(client.dispose);
      final session = BridgeLoginSession(client: client, flowId: 'phone');
      addTearDown(session.dispose);

      await session.start();
      await session.submitInput({'value': '+4915112345678'});
      final firstCode = session.currentStep!;
      expect(firstCode.fields.single.type, '2fa_code');
      expect(firstCode.instructions, 'Enter the login code Telegram sent you');

      await session.submitInput({'value': '11111'});
      expect(session.currentStep!.instructions, 'Incorrect code');
      expect(
        session.currentStep!.stepId,
        isNot(firstCode.stepId),
        reason: 'a repeated question is a new step, so the field clears',
      );

      await session.submitInput({'value': '22222'});
      expect(session.currentStep!.fields.single.isSecret, isTrue);
      expect(
        session.currentStep!.instructions,
        'You have two-factor authentication enabled.',
      );

      await session.submitInput({'value': 'hunter2'});
      expect(session.status, BridgeLoginStatus.complete);
    });

    test('"Invalid value" keeps the step open with the reason', () async {
      final bot = _FakeBot((command, bot) {
        if (command == 'list-logins') {
          return [_text(bot, "You're not logged in")];
        }
        if (command == 'login phone') {
          return [_text(bot, 'Please enter your Phone number')];
        }
        return [_text(bot, 'Invalid value: phone number must start with +')];
      });
      final client = _client(bot);
      addTearDown(client.dispose);
      final session = BridgeLoginSession(client: client, flowId: 'phone');
      addTearDown(session.dispose);

      await session.start();
      final step = session.currentStep;
      await session.submitInput({'value': '0151 1234567'});

      expect(session.status, BridgeLoginStatus.waitingForUser);
      expect(session.problem, BridgeLoginProblem.invalidInput);
      expect(session.error, 'phone number must start with +');
      expect(session.currentStep, same(step));
    });
  });

  group('other steps', () {
    test('Google account cookies surface as a cookies step', () async {
      final bot = _FakeBot((command, bot) {
        if (command == 'list-logins') {
          return [_text(bot, "You're not logged in")];
        }
        return [
          _text(
            bot,
            'Enter a JSON object with your cookies, or a cURL command copied '
            'from browser devtools.',
          ),
          _text(bot, 'Login URL: <https://accounts.google.com/AccountChooser>'),
        ];
      });
      final client = _client(bot);
      addTearDown(client.dispose);

      final step = await client.startLogin('google');

      expect(step.type, LoginStepType.cookies);
      expect(step.cookies!.url, 'https://accounts.google.com/AccountChooser');
      expect(client.supportsCookies, isFalse);
    });

    test('an emoji to tap is a display step', () async {
      final bot = _FakeBot((command, bot) {
        if (command == 'list-logins') {
          return [_text(bot, "You're not logged in")];
        }
        return [
          _text(bot, 'Tap the emoji on the Google Messages app on your phone'),
          _text(bot, '🦊'),
        ];
      });
      final client = _client(bot);
      addTearDown(client.dispose);

      final step = await client.startLogin('qr');

      expect(step.type, LoginStepType.displayAndWait);
      expect(step.displayType, 'emoji');
      expect(step.displayData, '🦊');
    });

    test('already signed in and the login limit carry codes', () async {
      final bot = _FakeBot((command, bot) {
        if (command == 'list-logins') {
          return [_text(bot, "You're not logged in")];
        }
        return [
          _text(
            bot,
            'You have reached the maximum number of logins (1). Please logout '
            'from an existing login before creating a new one.',
          ),
        ];
      });
      final client = _client(bot);
      addTearDown(client.dispose);

      await expectLater(
        client.startLogin('qr'),
        throwsA(
          isA<BridgeException>().having(
            (e) => e.errorCode,
            'errorCode',
            BridgeCommandClient.errorTooManyLogins,
          ),
        ),
      );
    });

    test('a relogin names the account', () async {
      final bot = _FakeBot((command, bot) {
        if (command == 'list-logins') {
          return [_text(bot, '* `777` (Anna) - `BAD_CREDENTIALS`')];
        }
        return [_text(bot, 'Please enter your Phone number')];
      });
      final client = _client(bot);
      addTearDown(client.dispose);

      await client.startLogin('phone', reloginId: '777');

      expect(bot.sent.last, 'relogin 777 phone');
    });

    test('logout and cancel are the bot\'s own commands', () async {
      final bot = _FakeBot((command, bot) {
        if (command == 'list-logins') {
          return [_text(bot, "You're not logged in")];
        }
        if (command.startsWith('logout')) return [_text(bot, 'Logged out')];
        return [_text(bot, 'Login cancelled.')];
      });
      final client = _client(bot);
      addTearDown(client.dispose);

      await client.logout('777');
      await client.cancelLogin('chat');

      expect(bot.sent, ['list-logins', 'logout 777', 'cancel']);
    });
  });

  group('legacy Discord', () {
    _FakeBot discord() => _FakeBot((command, bot) {
      if (command == 'list-logins') {
        return [
          _text(bot, 'Unknown command, use the `help` command for help.'),
        ];
      }
      if (command == 'login') {
        return [_image(bot, 'https://discord.com/ra/abc')];
      }
      if (command.startsWith('login-token user ')) {
        return [
          _text(bot, 'Connecting to Discord as user ID 123'),
          _text(bot, 'Successfully logged in as @anna'),
        ];
      }
      return const [];
    });

    test('QR, then success after the scan', () async {
      final bot = discord();
      final client = _client(bot);
      addTearDown(client.dispose);
      final session = BridgeLoginSession(client: client, flowId: 'qr');
      addTearDown(session.dispose);

      final done = session.start();
      await _until(() => session.status == BridgeLoginStatus.waitingForRemote);
      expect(session.currentStep!.displayData, 'https://discord.com/ra/abc');
      bot.say([_text(bot, 'Successfully logged in as @anna')]);
      await done;

      expect(session.status, BridgeLoginStatus.complete);
      expect(bot.sent, ['list-logins', 'login']);
    });

    test('a token is asked for on screen and sent inline', () async {
      final bot = discord();
      final client = _client(bot);
      addTearDown(client.dispose);
      final session = BridgeLoginSession(client: client, flowId: 'token');
      addTearDown(session.dispose);

      await session.start();
      expect(session.currentStep!.fields.single.isSecret, isTrue);
      expect(bot.sent, ['list-logins'], reason: 'nothing typed yet');

      await session.submitInput({'token': 'mfa.secret'});

      expect(bot.sent.last, 'login-token user mfa.secret');
      expect(session.status, BridgeLoginStatus.complete);
    });

    test('a captcha refusal carries a code of its own', () async {
      final bot = _FakeBot((command, bot) {
        if (command == 'list-logins') {
          return [
            _text(bot, 'Unknown command, use the `help` command for help.'),
          ];
        }
        return [_image(bot, 'https://discord.com/ra/abc')];
      });
      final client = _client(bot);
      addTearDown(client.dispose);
      final session = BridgeLoginSession(client: client, flowId: 'qr');
      addTearDown(session.dispose);

      final done = session.start();
      await _until(() => session.status == BridgeLoginStatus.waitingForRemote);
      bot.say([
        _text(
          bot,
          'Error logging in: 400 captcha-required\n\nCAPTCHAs are currently '
          'not supported - use token login instead',
        ),
      ]);
      await done;

      expect(session.errorCode, 'CHAT.SENNIT.CAPTCHA');
    });
  });
}

/// Pumps the event loop until [condition] holds, for at most a second.
Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 200 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue, reason: 'condition never became true');
}
