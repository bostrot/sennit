import 'package:flutter_test/flutter_test.dart';
import 'package:weft/features/contact/native_app_link.dart';
import 'package:weft_domain/weft_domain.dart';

/// Opening a contact in the network's own app: a link to the person, or none.
void main() {
  NetworkHandle handle(
    ChatNetwork network,
    String remoteId, {
    String? phone,
    String? email,
  }) => NetworkHandle(
    id: '$network:$remoteId',
    network: network,
    remoteId: remoteId,
    matrixUserId: '@${network.id}_$remoteId:example.org',
    phoneE164: phone,
    email: email,
  );

  String? link(NetworkHandle h) => nativeAppLink(h)?.toString();

  test('phone-number networks open the chat with that number', () {
    expect(
      link(handle(ChatNetwork.whatsapp, '4915112345678')),
      'https://wa.me/4915112345678',
    );
    expect(
      link(
        handle(
          ChatNetwork.signal,
          '0d6c1f4e-8f4a-4bd1-9a51-1f1c2b6b0a77',
          phone: '+4915112345678',
        ),
      ),
      'https://signal.me/#p/+4915112345678',
    );
    expect(
      link(handle(ChatNetwork.sms, '+4915112345678', phone: '+4915112345678')),
      'sms:+4915112345678',
    );
  });

  test('id networks open the profile by its id', () {
    expect(
      link(handle(ChatNetwork.telegram, '123456789')),
      'tg://user?id=123456789',
    );
    expect(
      link(handle(ChatNetwork.telegram, '123456789', phone: '+4915112345678')),
      'https://t.me/+4915112345678',
    );
    expect(
      link(handle(ChatNetwork.messenger, '1000123')),
      'https://m.me/1000123',
    );
    expect(
      link(handle(ChatNetwork.discord, '80351110224678912')),
      'https://discord.com/users/80351110224678912',
    );
    expect(
      link(handle(ChatNetwork.email, 'ada', email: 'ada@example.org')),
      'mailto:ada@example.org',
    );
  });

  test('no link rather than a wrong one', () {
    // A Signal account id is not a number to open.
    expect(link(handle(ChatNetwork.signal, '0d6c1f4e-8f4a')), isNull);
    // Instagram needs a username Sennit never learns.
    expect(link(handle(ChatNetwork.instagram, '1234')), isNull);
    // Sennit is the Matrix app.
    expect(link(handle(ChatNetwork.matrix, '@ada:example.org')), isNull);
    expect(link(handle(ChatNetwork.discord, 'not-a-snowflake')), isNull);
  });
}
