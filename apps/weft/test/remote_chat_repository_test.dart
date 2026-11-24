import 'package:flutter_test/flutter_test.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft/data/remote_chat_repository.dart';
import 'package:weft/services/remote/remote_chat_host.dart';
import 'package:weft_remote/weft_remote.dart';

/// The browser's repository against the phone's host, serving the demo
/// repository, over an in-memory link — the whole protocol in one process.
void main() {
  late DemoChatRepository phone;
  late RemoteChatHost host;
  late RemoteChatRepository browser;

  setUp(() async {
    phone = DemoChatRepository(uploadTick: Duration.zero);
    final link = linkedPair();
    host = RemoteChatHost(phone, link.a);
    browser = RemoteChatRepository(link.b);
    await browser.connect();
  });

  tearDown(() async {
    await browser.dispose();
    host.dispose();
  });

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('the browser inbox is the phone inbox', () async {
    final onPhone = await phone.watchChats().first;
    final inBrowser = await browser.watchChats().first;
    expect(
      [for (final c in inBrowser) (c.id, c.title, c.unreadCount)],
      [for (final c in onPhone) (c.id, c.title, c.unreadCount)],
    );
    expect(browser.availableNetworks, phone.availableNetworks);
    expect(
      browser.chatForRoom(onPhone.first.sources.first.roomId)?.id,
      onPhone.first.id,
    );
  });

  test('a merged timeline carries every leg and pages older history', () async {
    final chat = (await phone.watchChats().first).firstWhere(
      (c) => c.sources.length > 1,
    );
    final local = await phone.timelineFor(chat.id);
    final remote = await browser.timelineFor(chat.id);
    expect(
      remote.sources.map((s) => s.roomId).toSet(),
      local.sources.map((s) => s.roomId).toSet(),
    );
    expect(
      remote.view().messages.map((m) => m.eventId).toList(),
      local.view().messages.map((m) => m.eventId).toList(),
    );
    final source = remote.sources.firstWhere(
      (s) => s.hasMore,
      orElse: () => remote.sources.first,
    );
    final before = source.loaded.length;
    final added = await source.loadMore(count: 5);
    expect(source.loaded.length, before + added);
  });

  test('sending from the browser reaches the phone and comes back', () async {
    final chat = (await browser.watchChats().first).first;
    await browser.send(chat.id, 'sent from a browser');
    await settle();
    final onPhone = (await phone.watchChats().first).firstWhere(
      (c) => c.id == chat.id,
    );
    expect(onPhone.lastMessage?.body, 'sent from a browser');
    final inBrowser = (await browser.watchChats().first).firstWhere(
      (c) => c.id == chat.id,
    );
    expect(inBrowser.lastMessage?.body, 'sent from a browser');
  });

  test('a merge made in the browser lands in the phone graph', () async {
    final handles = phone.identityGraph.handles.toList();
    final a = handles.firstWhere(
      (h) => phone.identityGraph.contactIdOf(h.id) != null,
    );
    final b = handles.firstWhere(
      (h) =>
          h.id != a.id &&
          phone.identityGraph.contactIdOf(h.id) !=
              phone.identityGraph.contactIdOf(a.id),
    );
    await browser.mergeHandles(a.id, b.id);
    await settle();
    expect(
      phone.identityGraph.contactIdOf(a.id),
      phone.identityGraph.contactIdOf(b.id),
    );
    expect(
      browser.identityGraph.contactIdOf(a.id),
      browser.identityGraph.contactIdOf(b.id),
    );
  });

  test('an unknown chat is the ArgumentError screens already handle', () {
    expect(browser.timelineFor('no-such-chat'), throwsArgumentError);
  });

  test('a closed phone fails calls instead of hanging', () async {
    host.dispose();
    await settle();
    final chat = (await browser.watchChats().first).first;
    await expectLater(
      browser.markRead(chat.id),
      throwsA(isA<RemoteException>()),
    );
  });
}
