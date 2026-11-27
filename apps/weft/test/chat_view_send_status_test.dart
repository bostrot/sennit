import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/localisation.dart';
import 'package:weft/app/providers.dart';
import 'package:weft/data/chat_repository.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft/features/chat/chat_view.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_merge/weft_merge.dart';

import 'support/recording_repository.dart';

const _room = '!anna_wa_room:example.org';

WeftMessage _message(
  String id, {
  required bool own,
  required int minute,
  DeliveryState? delivery,
}) => WeftMessage(
  eventId: id,
  roomId: _room,
  network: ChatNetwork.whatsapp,
  senderId: own ? '@me:example.org' : '@anna:example.org',
  senderName: own ? 'Me' : 'Anna',
  timestamp: DateTime.utc(2026, 11, 26, 16, minute),
  kind: MessageKind.text,
  isOwn: own,
  body: own ? 'when do you need the HDDs?' : 'one sec',
  deliveryState: delivery,
);

/// One room whose messages the test rewrites, the way the SDK rewrites a
/// local echo in place.
class _Source extends TimelineSource {
  _Source(this.loaded);

  @override
  List<WeftMessage> loaded;

  @override
  String get roomId => _room;

  @override
  ChatNetwork get network => ChatNetwork.whatsapp;

  @override
  bool get hasMore => false;

  @override
  Future<int> loadMore({int count = 30}) async => 0;
}

/// The demo inbox over a timeline the test controls, with a heartbeat the
/// test beats — a sync on the phone, a pushed frame in the browser.
class _Repository extends RecordingChatRepository {
  _Repository(this.source) : super(DemoChatRepository());

  final _Source source;
  final _beats = StreamController<List<Chat>>.broadcast();

  @override
  Stream<List<Chat>> watchChats() async* {
    yield await inner.watchChats().first;
    yield* _beats.stream;
  }

  @override
  Future<MergedTimeline> timelineFor(String chatId) async =>
      MergedTimeline(sources: [source]);

  /// A fresh list, as every sync makes one.
  Future<void> beat() async =>
      _beats.add(List.of(await inner.watchChats().first));

  Future<void> dispose() => _beats.close();
}

class _Current extends Notifier<ChatRepository> {
  _Current(this._first);

  final ChatRepository _first;

  @override
  ChatRepository build() => _first;

  void set(ChatRepository repository) => state = repository;
}

void main() {
  late NotifierProvider<_Current, ChatRepository> current;

  Future<void> pump(WidgetTester tester, ChatRepository repository) {
    current = NotifierProvider<_Current, ChatRepository>(
      () => _Current(repository),
    );
    return tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatRepositoryProvider.overrideWith((ref) => ref.watch(current)),
        ],
        child: MaterialApp(
          localizationsDelegates: weftLocalizationsDelegates,
          theme: WeftTheme.build(),
          home: const ChatView(chatId: 'merged:anna'),
        ),
      ),
    );
  }

  Finder clock() => find.byIcon(Icons.schedule_rounded);

  // The reply landed while the send was in flight, so the send is not the
  // newest message: its id and status change in place, and the count and
  // newest id the screen compared stayed put.
  testWidgets('a send behind a newer message loses its clock', (tester) async {
    final source = _Source([
      _message(r'$reply', own: false, minute: 21),
      _message('txn-1', own: true, minute: 20, delivery: DeliveryState.sending),
    ]);
    final repository = _Repository(source);
    addTearDown(repository.dispose);
    await pump(tester, repository);
    await tester.pumpAndSettle();
    expect(clock(), findsOneWidget);

    source.loaded = [
      source.loaded.first,
      _message(r'$sent', own: true, minute: 20, delivery: DeliveryState.sent),
    ];
    await repository.beat();
    await tester.pumpAndSettle();

    expect(clock(), findsNothing);
    expect(find.byIcon(Icons.done_rounded), findsOneWidget);

    // And on to delivered, with the id unchanged.
    source.loaded = [
      source.loaded.first,
      _message(
        r'$sent',
        own: true,
        minute: 20,
        delivery: DeliveryState.delivered,
      ),
    ];
    await repository.beat();
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.done_all_rounded), findsOneWidget);
  });

  // Sennit Web builds a new repository each time the link to the phone comes
  // back. The open conversation has to move to it: the old one's timeline
  // never changes again, and a send pushed just before the drop kept its clock
  // although the phone had long sent it.
  testWidgets('a new repository reopens the conversation', (tester) async {
    final before = _Repository(
      _Source([
        _message(
          'txn-1',
          own: true,
          minute: 20,
          delivery: DeliveryState.sending,
        ),
      ]),
    );
    addTearDown(before.dispose);
    await pump(tester, before);
    await tester.pumpAndSettle();
    expect(clock(), findsOneWidget);

    final after = _Repository(
      _Source([
        _message(
          r'$sent',
          own: true,
          minute: 20,
          delivery: DeliveryState.delivered,
        ),
      ]),
    );
    addTearDown(after.dispose);
    ProviderScope.containerOf(
      tester.element(find.byType(ChatView)),
    ).read(current.notifier).set(after);
    await tester.pumpAndSettle();

    expect(clock(), findsNothing);
    expect(find.byIcon(Icons.done_all_rounded), findsOneWidget);
  });

  // The SDK's own English error ("The sender has not sent us the session
  // key.") used to be the bubble's text, in every language; a key that comes
  // in later turns the same event into the message in place.
  testWidgets('a message without its key says so in the app\'s words', (
    tester,
  ) async {
    final locked = WeftMessage(
      eventId: r'$locked',
      roomId: _room,
      network: ChatNetwork.whatsapp,
      senderId: '@anna:example.org',
      senderName: 'Anna',
      timestamp: DateTime.utc(2026, 11, 26, 16, 20),
      kind: MessageKind.text,
      isOwn: false,
      undecryptable: true,
    );
    final source = _Source([locked]);
    final repository = _Repository(source);
    addTearDown(repository.dispose);
    await pump(tester, repository);
    await tester.pumpAndSettle();
    expect(find.text('Encrypted message'), findsWidgets);
    expect(find.textContaining('Verify this device'), findsOneWidget);

    source.loaded = [_message(r'$locked', own: false, minute: 20)];
    await repository.beat();
    await tester.pumpAndSettle();
    expect(find.textContaining('Verify this device'), findsNothing);
    expect(find.text('one sec'), findsWidgets);
  });
}
