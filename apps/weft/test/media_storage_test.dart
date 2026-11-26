/// Automatic media download and the space downloads take.
///
/// Two claims. With automatic download off, a picture in the timeline fetches
/// nothing until it is tapped — a sticker excepted. And the storage helper
/// counts what is cached, trims the oldest first down to a limit, and leaves a
/// download still being written alone.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:weft/app/localisation.dart';
import 'package:weft/app/providers.dart';
import 'package:weft/features/chat/attachment_bubble.dart';
import 'package:weft/features/settings/storage_screen.dart';
import 'package:weft/services/attachments/local_media_storage.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft/app/stores.dart';
import 'package:weft_store/weft_store.dart';

import 'support/attachment_fixtures.dart';

/// Answers from memory, so the screen can be driven without a file system.
class _FakeStorage extends LocalMediaStorage {
  int used = 5 * 1024 * 1024;
  final List<int?> trims = [];

  @override
  Future<int> usedBytes() async => used;

  @override
  Future<int> clear() async {
    final freed = used;
    used = 0;
    return freed;
  }

  @override
  Future<int> trimTo(int? maxBytes) async {
    trims.add(maxBytes);
    return 0;
  }
}

void main() {
  final en = lookupAppL10n(const Locale('en'));

  group('automatic download off', () {
    WeftMessage message(MessageKind kind) => WeftMessage(
      eventId: '\$event',
      roomId: '!room:example.org',
      network: ChatNetwork.matrix,
      senderId: '@anna:example.org',
      senderName: 'Anna',
      timestamp: DateTime(2026, 3, 4, 9, 30),
      kind: kind,
      isOwn: false,
      body: 'holiday.jpg',
      attachmentUrl: '\$event',
      mediaSizeBytes: 3 * 1024 * 1024,
    );

    Future<StubChatRepository> pump(
      WidgetTester tester,
      WeftMessage message,
    ) async {
      final repository = StubChatRepository(bytes: kPixel);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            chatRepositoryProvider.overrideWithValue(repository),
            mediaAutoDownloadProvider.overrideWithValue(false),
          ],
          child: MaterialApp(
            localizationsDelegates: weftLocalizationsDelegates,
            theme: WeftTheme.build(),
            home: Scaffold(
              body: Center(
                child: AttachmentBubble(
                  message: message,
                  own: false,
                  onOpen: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return repository;
    }

    testWidgets('a photo waits for a tap, then loads', (tester) async {
      final repository = await pump(tester, message(MessageKind.image));

      expect(repository.byteCalls, 0);
      expect(find.byIcon(Icons.download_rounded), findsOneWidget);
      expect(find.text('3.0 MB'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.download_rounded));
      await tester.pumpAndSettle();
      expect(repository.byteCalls, 1);
      expect(find.byIcon(Icons.download_rounded), findsNothing);
    });

    testWidgets('a sticker still loads by itself', (tester) async {
      final repository = await pump(tester, message(MessageKind.sticker));
      expect(repository.byteCalls, 1);
      expect(find.byIcon(Icons.download_rounded), findsNothing);
    });
  });

  group('LocalMediaStorage', () {
    late Directory root;
    late Directory sdkFiles;
    late Directory staged;
    late LocalMediaStorage storage;

    File write(Directory dir, String name, int size, int ageDays) {
      final file = File(p.join(dir.path, name))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(List.filled(size, 0));
      file.setLastModifiedSync(
        DateTime.now().subtract(Duration(days: ageDays)),
      );
      return file;
    }

    setUp(() {
      root = Directory.systemTemp.createTempSync('weft-media-');
      sdkFiles = Directory(p.join(root.path, 'matrix', 'files'))
        ..createSync(recursive: true);
      staged = Directory(p.join(root.path, 'media'))..createSync();
      storage = LocalMediaStorage(directories: () async => [sdkFiles, staged]);
    });

    tearDown(() => root.deleteSync(recursive: true));

    test('counts both folders, but not a download in progress', () async {
      write(sdkFiles, 'a', 100, 1);
      write(staged, 'event1/photo.jpg', 50, 1);
      write(staged, 'event2/film.mp4.part', 1000, 0);
      expect(await storage.usedBytes(), 150);
    });

    test('trims the oldest first down to the limit', () async {
      final oldest = write(sdkFiles, 'old', 100, 20);
      final middle = write(staged, 'event1/photo.jpg', 100, 10);
      final newest = write(sdkFiles, 'new', 100, 1);

      expect(await storage.trimTo(250), 100);
      expect(oldest.existsSync(), isFalse);
      expect(middle.existsSync(), isTrue);
      expect(newest.existsSync(), isTrue);

      expect(await storage.trimTo(100), 100);
      expect(middle.existsSync(), isFalse);
      // The staging folder it sat in goes with it.
      expect(middle.parent.existsSync(), isFalse);
      expect(newest.existsSync(), isTrue);

      expect(await storage.trimTo(null), 0);
    });

    test('clears everything finished', () async {
      write(sdkFiles, 'a', 100, 1);
      write(staged, 'event1/photo.jpg', 50, 1);
      final part = write(staged, 'event2/film.mp4.part', 1000, 0);

      expect(await storage.clear(), 150);
      expect(await storage.usedBytes(), 0);
      expect(part.existsSync(), isTrue);
      // The roots themselves stay for the next download.
      expect(sdkFiles.existsSync(), isTrue);
      expect(staged.existsSync(), isTrue);
    });

    test('the limit reads from settings, zero being none', () {
      final settings = WeftStores.inMemory().settings;
      expect(mediaLimitBytes(settings), kDefaultMediaLimitMb * 1024 * 1024);
      settings.setInt(WeftSettings.mediaLimitMb, 500);
      expect(mediaLimitBytes(settings), 500 * 1024 * 1024);
      settings.setInt(WeftSettings.mediaLimitMb, 0);
      expect(mediaLimitBytes(settings), isNull);
      expect(mediaAutoDownload(settings), isTrue);
    });
  });

  group('storage screen', () {
    testWidgets('shows the space used, sets a limit and clears', (
      tester,
    ) async {
      final stores = WeftStores.inMemory();
      final storage = _FakeStorage();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            storesProvider.overrideWithValue(stores),
            localMediaStorageProvider.overrideWithValue(storage),
          ],
          child: MaterialApp(
            localizationsDelegates: weftLocalizationsDelegates,
            theme: WeftTheme.build(),
            home: const StorageScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(en.storageUsed('5.0 MB')), findsOneWidget);

      await tester.tap(find.text(en.storageAutoDownloadTitle));
      await tester.pumpAndSettle();
      expect(mediaAutoDownload(stores.settings), isFalse);

      await tester.tap(find.text('500 MB'));
      await tester.pumpAndSettle();
      expect(stores.settings.getInt(WeftSettings.mediaLimitMb), 500);
      expect(storage.trims, [500 * 1024 * 1024]);

      await tester.tap(find.text(en.storageClear));
      await tester.pumpAndSettle();
      expect(find.text(en.storageCleared('5.0 MB')), findsOneWidget);
      expect(find.text(en.storageUsed('0 B')), findsOneWidget);
    });
  });
}
