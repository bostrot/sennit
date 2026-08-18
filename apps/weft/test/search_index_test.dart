import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/stores.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_search/weft_search.dart';

/// What the index does with a formatted body.
///
/// The store is the one door into the index — every writer goes through
/// `indexMessage`, and both the FTS row and the embedding text come off the
/// column it writes — so this exercises the real `SearchStore` against a real
/// SQLite database rather than a fake. Keyword mode throughout: no embedding
/// endpoint is configured in a test, and keyword search is the half that reads
/// the stored text directly.
void main() {
  late WeftStores stores;
  late SearchEngine engine;

  setUp(() {
    stores = WeftStores.inMemory();
    engine = SearchEngine(backend: stores.search);
  });

  tearDown(() => stores.dispose());

  WeftMessage message({
    String eventId = r'$e1',
    String body = 'hello',
    String? formattedBody,
    String? transcript,
    MessageKind kind = MessageKind.text,
  }) => WeftMessage(
    eventId: eventId,
    roomId: '!room:example.org',
    network: ChatNetwork.whatsapp,
    senderId: '@grace:example.org',
    senderName: 'Grace',
    timestamp: DateTime.utc(2026, 8, 18, 14),
    kind: kind,
    isOwn: false,
    body: body,
    formattedBody: formattedBody,
    transcript: transcript,
  );

  void index(WeftMessage m) =>
      stores.search.indexMessage(m, chatId: '!room:example.org');

  Future<List<SearchResult>> find(String text) =>
      engine.search(SearchQuery(text: text, mode: SearchMode.keyword));

  test('a formatted message is findable by its visible words', () async {
    index(
      message(
        body: 'the roof is on fire',
        formattedBody: '<p>the roof is <b>on fire</b></p>',
      ),
    );

    final hits = await find('fire');
    expect(hits, hasLength(1));
    expect(hits.single.eventId, r'$e1');
    // And what comes back is readable: the search screen prints this body, so
    // a stored `<b>` would be shown to the user as well as matched on.
    expect(hits.single.body, 'the roof is on fire');
  });

  test('tag names are not words the message contains', () async {
    index(
      message(
        body: 'the roof is on fire',
        formattedBody:
            '<p>the roof is <b>on fire</b></p>'
            '<blockquote>said Grace</blockquote>',
      ),
    );

    // Indexing raw HTML makes every formatted message a hit for the vocabulary
    // of HTML — which is worse than useless, because those hits crowd out the
    // real ones for anyone who happens to be discussing markup.
    expect(await find('blockquote'), isEmpty);
    expect(await find('href'), isEmpty);
  });

  test('a payload the reader never saw does not reach the index', () async {
    index(
      message(
        body: 'look at this',
        formattedBody:
            '<p>look at this</p>'
            '<script>stealCredentials()</script>'
            '<style>.tracker{}</style>',
      ),
    );

    // A dropped subtree is dropped everywhere. The search screen renders result
    // bodies, so text that was never shown in a bubble must not surface there.
    expect(await find('stealCredentials'), isEmpty);
    expect(await find('tracker'), isEmpty);
    expect(await find('look'), hasLength(1));
  });

  test('a mention is findable by the name the sender wrote', () async {
    index(
      message(
        body: 'Alice is here',
        formattedBody:
            '<a href="https://matrix.to/#/@alice:example.org">Alice</a> '
            'is here',
      ),
    );

    expect(await find('Alice'), hasLength(1));
    // The permalink is markup, not words: `matrix.to` in the index would make
    // every mention in the history a hit for a search about that domain.
    expect(await find('matrix.to'), isEmpty);
  });

  test('a reply is findable by the answer, not by what it quoted', () async {
    index(
      message(
        body:
            '> <@grace:example.org> are we still on for six\n'
            '\n'
            'yes, see you there',
      ),
    );

    expect(await find('yes'), hasLength(1));
    // The quoted line belongs to the message being answered, which is indexed
    // under its own event id. Indexing it twice makes one search return both
    // bubbles and the reader cannot tell which of them actually said it.
    expect(await find('still'), isEmpty);
  });

  test('a voice note is still findable by its transcript', () async {
    index(
      message(
        kind: MessageKind.voice,
        body: 'Voice message.ogg',
        transcript: 'running ten minutes late',
      ),
    );

    expect(await find('minutes'), hasLength(1));
    expect(await find('ogg'), hasLength(1));
  });

  test('an edited message re-indexes to what it now says', () async {
    index(message(body: 'six', formattedBody: '<b>six</b>'));
    index(message(body: 'seven', formattedBody: '<b>seven</b>'));

    expect(await find('six'), isEmpty);
    expect(await find('seven'), hasLength(1));
    expect(stores.search.indexedCount, 1);
  });
}
