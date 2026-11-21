/// The gate, the cache and the request counting behind link previews.
///
/// Deliberately below the widget layer. What matters here is not what a card
/// looks like but *how many questions the homeserver was asked and when* —
/// which is the privacy property the whole feature is built on, and which a
/// pumped widget can only observe indirectly. Every test in this file therefore
/// counts calls to the fetcher.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/stores.dart';
import 'package:weft/services/links/link_preview_service.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_richtext/weft_richtext.dart';
import 'package:weft_store/weft_store.dart';

const String _url = 'https://example.org/a';

LinkPreview _preview([String title = 'A title']) =>
    LinkPreview(url: _url, title: title);

/// A fetcher that records what it was asked and answers from a script.
class _Fetcher {
  _Fetcher({this.answer});

  final LinkPreview? Function(Uri url)? answer;
  final List<Uri> asked = [];

  int get calls => asked.length;

  Future<LinkPreview?> call(Uri url) async {
    asked.add(url);
    return answer?.call(url);
  }
}

void main() {
  late WeftStores stores;

  setUp(() => stores = WeftStores.inMemory());
  tearDown(() => stores.dispose());

  group('LinkPreviewSettings', () {
    test('is on for plain rooms and off for encrypted ones before anyone '
        'configures it', () {
      final settings = LinkPreviewSettings.fromStore(stores.settings);
      expect(settings.enabled, isTrue);
      expect(settings.encryptedRooms, isFalse);
      expect(settings.excludedNetworks, isEmpty);
      expect(settings.allows(ChatNetwork.signal), isTrue);
      // The disclosure that is not free — a url the homeserver could not
      // otherwise read — is the one that waits for the user.
      expect(settings.allows(ChatNetwork.signal, encrypted: true), isFalse);
      expect(settings.showsCards(ChatNetwork.signal), isTrue);
    });

    test('a user who switched previews off stays switched off', () {
      // Written by a build where off was the default, or by the user today:
      // either way an explicit "false" is an answer and the new default must
      // not overrule it.
      stores.settings.setBool(WeftSettings.linkPreviewEnabled, value: false);
      final settings = LinkPreviewSettings.fromStore(stores.settings);
      expect(settings.enabled, isFalse);
      expect(settings.allows(ChatNetwork.matrix), isFalse);
      expect(settings.showsCards(ChatNetwork.matrix), isFalse);
    });

    test('off is off everywhere, encrypted switch or not', () {
      const settings = LinkPreviewSettings(
        enabled: false,
        encryptedRooms: true,
      );
      expect(settings.allows(ChatNetwork.matrix), isFalse);
      expect(settings.allows(ChatNetwork.matrix, encrypted: true), isFalse);
      expect(settings.showsCards(ChatNetwork.matrix), isFalse);
    });

    test('the encrypted switch opens encrypted rooms and nothing else', () {
      const settings = LinkPreviewSettings(
        encryptedRooms: true,
        excludedNetworks: {'signal'},
      );
      expect(settings.allows(ChatNetwork.matrix, encrypted: true), isTrue);
      expect(settings.allows(ChatNetwork.signal, encrypted: true), isFalse);
      expect(settings.allows(ChatNetwork.signal), isFalse);
    });

    test('round-trips through the settings store', () {
      const written = LinkPreviewSettings(
        encryptedRooms: true,
        excludedNetworks: {'signal', 'whatsapp'},
      );
      written.writeTo(stores.settings);

      final read = LinkPreviewSettings.fromStore(stores.settings);
      expect(read, written);
      expect(read.allows(ChatNetwork.matrix), isTrue);
      expect(read.allows(ChatNetwork.signal), isFalse);
    });

    test('an excluded network stays excluded when the master switch is on', () {
      const settings = LinkPreviewSettings(
        enabled: true,
        excludedNetworks: {'signal'},
      );
      expect(settings.allows(ChatNetwork.signal), isFalse);
      expect(settings.allows(ChatNetwork.telegram), isTrue);
    });

    test(
      'a corrupt exclusion list reads as nothing excluded, not as a crash',
      () {
        stores.settings.setBool(WeftSettings.linkPreviewEnabled, value: true);
        stores.settings.setJson(WeftSettings.linkPreviewExcludedNetworks, {
          'networks': ['signal', 7, null],
        });

        final read = LinkPreviewSettings.fromStore(stores.settings);
        expect(read.excludedNetworks, {'signal'});
      },
    );
  });

  group('the gate', () {
    test('asks nothing about a link in an encrypted room by default', () async {
      final fetcher = _Fetcher(answer: (_) => _preview());
      final service = LinkPreviewService(
        settings: const LinkPreviewSettings(),
        cache: stores.linkPreviews,
        fetch: fetcher.call,
      );

      expect(
        await service.previewFor(
          _url,
          network: ChatNetwork.matrix,
          encrypted: true,
        ),
        isNull,
      );
      expect(
        service.peek(_url, network: ChatNetwork.matrix, encrypted: true).known,
        isTrue,
        reason: 'a closed gate is a known "nothing", not a reason to ask',
      );
      expect(fetcher.calls, 0);

      // The same url in a plain room is a different question.
      expect(
        (await service.previewFor(_url, network: ChatNetwork.matrix))?.title,
        'A title',
      );
      expect(fetcher.calls, 1);
    });

    test('asks about an encrypted room once the user allowed it', () async {
      final fetcher = _Fetcher(answer: (_) => _preview());
      final service = LinkPreviewService(
        settings: const LinkPreviewSettings(encryptedRooms: true),
        fetch: fetcher.call,
      );

      expect(
        (await service.previewFor(
          _url,
          network: ChatNetwork.matrix,
          encrypted: true,
        ))?.title,
        'A title',
      );
      expect(fetcher.calls, 1);
    });

    test('asks nothing at all while previews are off', () async {
      final fetcher = _Fetcher(answer: (_) => _preview());
      final service = LinkPreviewService(
        settings: LinkPreviewSettings.off,
        cache: stores.linkPreviews,
        fetch: fetcher.call,
      );

      expect(await service.previewFor(_url, network: ChatNetwork.matrix), null);
      expect(fetcher.calls, 0);
      expect(stores.linkPreviews.count, 0);
    });

    test('asks nothing for an excluded network', () async {
      final fetcher = _Fetcher(answer: (_) => _preview());
      final service = LinkPreviewService(
        settings: const LinkPreviewSettings(
          enabled: true,
          excludedNetworks: {'signal'},
        ),
        cache: stores.linkPreviews,
        fetch: fetcher.call,
      );

      expect(await service.previewFor(_url, network: ChatNetwork.signal), null);
      expect(fetcher.calls, 0);

      expect(
        await service.previewFor(_url, network: ChatNetwork.telegram),
        isNotNull,
      );
      expect(fetcher.calls, 1);
    });

    test('refuses a scheme with no page behind it', () async {
      final fetcher = _Fetcher(answer: (_) => _preview());
      final service = LinkPreviewService(
        settings: const LinkPreviewSettings(enabled: true),
        cache: stores.linkPreviews,
        fetch: fetcher.call,
      );

      for (final url in [
        'mailto:anna@example.org',
        'javascript:alert(1)',
        'data:text/html,x',
        '/relative/path',
      ]) {
        expect(
          await service.previewFor(url, network: ChatNetwork.matrix),
          null,
        );
      }
      expect(fetcher.calls, 0);
    });

    test('answers nothing, rather than throwing, with no homeserver', () async {
      final service = LinkPreviewService(
        settings: const LinkPreviewSettings(enabled: true),
        cache: stores.linkPreviews,
      );
      expect(await service.previewFor(_url, network: ChatNetwork.matrix), null);
      // Nothing was asked, so nothing is remembered: a session that comes up
      // later must not find a cached "no" it never got an answer for.
      expect(stores.linkPreviews.count, 0);
    });
  });

  group('the cache', () {
    test('asks once for a url however many bubbles show it', () async {
      final fetcher = _Fetcher(answer: (_) => _preview());
      final service = LinkPreviewService(
        settings: const LinkPreviewSettings(enabled: true),
        cache: stores.linkPreviews,
        fetch: fetcher.call,
      );

      await service.previewFor(_url, network: ChatNetwork.matrix);
      await service.previewFor(_url, network: ChatNetwork.matrix);
      final third = await service.previewFor(_url, network: ChatNetwork.signal);

      expect(fetcher.calls, 1);
      expect(third?.title, 'A title');
    });

    test('remembers "nothing there" so it is not re-asked forever', () async {
      final fetcher = _Fetcher(answer: (_) => null);
      final service = LinkPreviewService(
        settings: const LinkPreviewSettings(enabled: true),
        cache: stores.linkPreviews,
        fetch: fetcher.call,
      );

      expect(await service.previewFor(_url, network: ChatNetwork.matrix), null);
      expect(await service.previewFor(_url, network: ChatNetwork.matrix), null);

      expect(fetcher.calls, 1);
      expect(stores.linkPreviews.read(_url)!.isMiss, isTrue);
    });

    test(
      'an answer with no content is stored as a miss, not as a card',
      () async {
        // A homeserver answering `{}` for a page with no tags is not a failure,
        // but a card carrying only the url the reader can already see is noise.
        final fetcher = _Fetcher(answer: (_) => const LinkPreview(url: _url));
        final service = LinkPreviewService(
          settings: const LinkPreviewSettings(enabled: true),
          cache: stores.linkPreviews,
          fetch: fetcher.call,
        );

        expect(
          await service.previewFor(_url, network: ChatNetwork.matrix),
          null,
        );
        expect(stores.linkPreviews.read(_url)!.isMiss, isTrue);
      },
    );

    test('a stale hit is re-asked; a fresh one is not', () async {
      var now = DateTime.utc(2026, 8, 18, 12);
      final fetcher = _Fetcher(answer: (_) => _preview());
      final service = LinkPreviewService(
        settings: const LinkPreviewSettings(enabled: true),
        cache: stores.linkPreviews,
        fetch: fetcher.call,
        successTtl: const Duration(days: 7),
        now: () => now,
      );

      await service.previewFor(_url, network: ChatNetwork.matrix);
      now = now.add(const Duration(days: 6));
      await service.previewFor(_url, network: ChatNetwork.matrix);
      expect(fetcher.calls, 1);

      now = now.add(const Duration(days: 2));
      await service.previewFor(_url, network: ChatNetwork.matrix);
      expect(fetcher.calls, 2);
    });

    test(
      'a miss expires sooner than a hit, so a bad day is not permanent',
      () async {
        var now = DateTime.utc(2026, 8, 18, 12);
        final fetcher = _Fetcher(answer: (_) => null);
        final service = LinkPreviewService(
          settings: const LinkPreviewSettings(enabled: true),
          cache: stores.linkPreviews,
          fetch: fetcher.call,
          successTtl: const Duration(days: 7),
          missTtl: const Duration(hours: 6),
          now: () => now,
        );

        await service.previewFor(_url, network: ChatNetwork.matrix);
        now = now.add(const Duration(hours: 7));
        await service.previewFor(_url, network: ChatNetwork.matrix);

        expect(fetcher.calls, 2);
      },
    );

    test('two bubbles in one frame make one request', () async {
      final completer = <Uri>[];
      var released = false;
      Future<LinkPreview?> slow(Uri url) async {
        completer.add(url);
        while (!released) {
          await Future<void>.delayed(Duration.zero);
        }
        return _preview();
      }

      final service = LinkPreviewService(
        settings: const LinkPreviewSettings(enabled: true),
        cache: stores.linkPreviews,
        fetch: slow,
      );

      final first = service.previewFor(_url, network: ChatNetwork.matrix);
      final second = service.previewFor(_url, network: ChatNetwork.matrix);
      released = true;

      expect((await first)?.title, 'A title');
      expect((await second)?.title, 'A title');
      expect(completer.length, 1);
    });

    test(
      'works with no cache at all, which is what a widget test has',
      () async {
        final fetcher = _Fetcher(answer: (_) => _preview());
        final service = LinkPreviewService(
          settings: const LinkPreviewSettings(enabled: true),
          fetch: fetcher.call,
        );

        expect(
          (await service.previewFor(_url, network: ChatNetwork.matrix))?.title,
          'A title',
        );
        expect(fetcher.calls, 1);
      },
    );
  });

  group('the memory cache', () {
    test(
      'a rebuilt service remembers without asking or reading disk',
      () async {
        final fetcher = _Fetcher(answer: (_) => _preview());
        final memory = LinkPreviewMemoryCache();
        LinkPreviewService build() => LinkPreviewService(
          settings: const LinkPreviewSettings(),
          cache: stores.linkPreviews,
          memory: memory,
          fetch: fetcher.call,
        );

        await build().previewFor(_url, network: ChatNetwork.matrix);
        // The disk row goes, the memory stays: what a settings change that
        // rebuilds the service — any settings change — must not cost.
        stores.linkPreviews.clear();
        final peek = build().peek(_url, network: ChatNetwork.matrix);

        expect(peek.known, isTrue);
        expect(peek.preview?.title, 'A title');
        expect(fetcher.calls, 1);
      },
    );

    test('peek reads the disk cache, so a restart draws in one frame', () {
      stores.linkPreviews.write(_url, _preview().toJson());
      final service = LinkPreviewService(
        settings: const LinkPreviewSettings(),
        cache: stores.linkPreviews,
      );

      final peek = service.peek(_url, network: ChatNetwork.matrix);
      expect(peek.known, isTrue);
      expect(peek.preview?.title, 'A title');
      expect(service.memory.length, 1);
    });

    test('peek of a url nobody asked about is unknown', () {
      final service = LinkPreviewService(
        settings: const LinkPreviewSettings(),
        cache: stores.linkPreviews,
      );
      expect(service.peek(_url, network: ChatNetwork.matrix).known, isFalse);
    });

    test('a stale memory entry is not trusted', () async {
      var now = DateTime.utc(2026, 11, 1);
      final fetcher = _Fetcher(answer: (_) => _preview());
      final service = LinkPreviewService(
        settings: const LinkPreviewSettings(),
        fetch: fetcher.call,
        now: () => now,
      );

      await service.previewFor(_url, network: ChatNetwork.matrix);
      now = now.add(const Duration(days: 8));
      expect(service.peek(_url, network: ChatNetwork.matrix).known, isFalse);
      await service.previewFor(_url, network: ChatNetwork.matrix);
      expect(fetcher.calls, 2);
    });

    test('evicts the oldest entry past its capacity', () {
      final memory = LinkPreviewMemoryCache(capacity: 2);
      final at = DateTime.utc(2026, 11, 1);
      for (final url in ['https://a.example', 'https://b.example']) {
        memory.write(CachedLinkPreview(url: url, preview: null, fetchedAt: at));
      }
      // Reading `a` makes `b` the oldest.
      memory
        ..read('https://a.example')
        ..write(
          CachedLinkPreview(
            url: 'https://c.example',
            preview: null,
            fetchedAt: at,
          ),
        );

      expect(memory.read('https://a.example'), isNotNull);
      expect(memory.read('https://b.example'), isNull);
      expect(memory.read('https://c.example'), isNotNull);
      expect(memory.length, 2);
    });
  });

  group('LinkPreviewStore', () {
    test('a never-asked url reads as null, not as a miss', () {
      expect(stores.linkPreviews.read(_url), isNull);
    });

    test('a miss and a hit are different answers', () {
      stores.linkPreviews.write(_url, null);
      stores.linkPreviews.write('https://example.org/b', {'title': 'B'});

      expect(stores.linkPreviews.read(_url)!.isMiss, isTrue);
      expect(
        stores.linkPreviews.read('https://example.org/b')!.isMiss,
        isFalse,
      );
    });

    test('writing the same url twice replaces rather than duplicates', () {
      stores.linkPreviews.write(_url, {'title': 'old'});
      stores.linkPreviews.write(_url, {'title': 'new'});

      expect(stores.linkPreviews.count, 1);
      expect(stores.linkPreviews.read(_url)!.preview, {'title': 'new'});
    });

    test('a corrupt row reads as a miss rather than crashing a scroll', () {
      stores.db.raw.execute(
        'INSERT INTO link_preview (url, preview, fetched_at) VALUES (?, ?, ?)',
        [_url, 'not json at all', 0],
      );
      expect(stores.linkPreviews.read(_url)!.isMiss, isTrue);
    });

    test('purgeBefore drops only what is older than the cutoff', () {
      final old = DateTime.utc(2026, 1, 1);
      final recent = DateTime.utc(2026, 8, 18);
      stores.linkPreviews.write(_url, {'title': 'A'}, at: old);
      stores.linkPreviews.write('https://example.org/b', {
        'title': 'B',
      }, at: recent);

      expect(stores.linkPreviews.purgeBefore(DateTime.utc(2026, 6, 1)), 1);
      expect(stores.linkPreviews.read(_url), isNull);
      expect(stores.linkPreviews.read('https://example.org/b'), isNotNull);
    });

    test('clear forgets everything, which is what switching off must do', () {
      stores.linkPreviews.write(_url, {'title': 'A'});
      stores.linkPreviews.write('https://example.org/b', null);

      stores.linkPreviews.clear();
      expect(stores.linkPreviews.count, 0);
    });
  });
}
