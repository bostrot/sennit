import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/localisation.dart';
import 'package:weft/app/providers.dart';
import 'package:weft/features/contact/avatar_viewer.dart';
import 'package:weft/features/contact/contact_profile.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import 'support/attachment_fixtures.dart';

/// Tapping the picture at the top of a contact's profile shows it full screen.
void main() {
  const small =
      'https://matrix.example.org/_matrix/client/v1/media/thumbnail'
      '/example.org/face?width=96&height=96&method=crop&animated=false';

  Chat chat({String? avatarUrl}) => Chat(
    id: '!grace:example.org',
    title: 'Grace Hopper',
    sources: const [
      ChatSource(roomId: '!grace:example.org', network: ChatNetwork.signal),
    ],
    avatarUrl: avatarUrl,
  );

  /// Every picture asked for, in order. Served from memory through the same
  /// hook Sennit Web uses, so nothing here touches the network.
  late List<String> requested;
  late StubChatRepository repository;

  setUp(() {
    requested = [];
    repository = StubChatRepository();
    weftAvatarImageOverride = (url) {
      requested.add(url);
      return MemoryImage(kPixel);
    };
  });

  tearDown(() {
    weftAvatarImageOverride = null;
    repository.dispose();
  });

  Future<void> pump(
    WidgetTester tester, {
    String? avatarUrl,
    Size size = const Size(400, 900),
    double textScale = 1,
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatRepositoryProvider.overrideWithValue(repository),
          chatsProvider.overrideWith(
            (ref) => Stream.value([chat(avatarUrl: avatarUrl)]),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: weftLocalizationsDelegates,
          supportedLocales: weftSupportedLocales,
          theme: WeftTheme.build(brightness: brightness),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: const ContactProfileScreen(chatId: '!grace:example.org'),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder profileAvatar() => find.byType(WeftAvatar).first;

  testWidgets('a picture opens full screen, asked for larger and uncropped', (
    tester,
  ) async {
    await pump(tester, avatarUrl: small);

    await tester.tap(profileAvatar());
    await tester.pumpAndSettle();

    expect(find.byType(AvatarViewer), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AvatarViewer),
        matching: find.text('Grace Hopper'),
      ),
      findsOneWidget,
    );
    final large = Uri.parse(requested.last);
    expect(large.path, Uri.parse(small).path);
    expect(large.queryParameters, containsPair('width', '800'));
    expect(large.queryParameters, containsPair('method', 'scale'));
    expect(tester.takeException(), isNull);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(AvatarViewer), findsNothing);
  });

  testWidgets('initials alone are not a button', (tester) async {
    final semantics = tester.ensureSemantics();
    await pump(tester);

    await tester.tap(profileAvatar());
    await tester.pumpAndSettle();

    expect(find.byType(AvatarViewer), findsNothing);
    expect(find.bySemanticsLabel(RegExp('View profile picture')), findsNothing);
    semantics.dispose();
  });

  testWidgets('a screen reader hears who it is and what a tap does', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pump(tester, avatarUrl: small);

    final node = tester.getSemantics(
      find
          .ancestor(of: profileAvatar(), matching: find.byType(Semantics))
          .first,
    );
    expect(node.label, contains('Grace Hopper'));
    expect(node.hint, 'View profile picture');
    expect(node.flagsCollection.isButton, isTrue);

    await tester.tap(profileAvatar());
    await tester.pumpAndSettle();
    expect(
      find.bySemanticsLabel('Profile picture of Grace Hopper'),
      findsOneWidget,
    );
    semantics.dispose();
  });

  // A URL that is not a Matrix thumbnail has no larger version: the viewer
  // shows what it has rather than asking for something that is not there.
  testWidgets('any other picture is shown as it is', (tester) async {
    const other = 'https://example.org/grace.png';
    await pump(tester, avatarUrl: other);

    await tester.tap(profileAvatar());
    await tester.pumpAndSettle();

    expect(find.byType(AvatarViewer), findsOneWidget);
    expect(requested.toSet(), {other});
  });

  for (final (name, size, scale, brightness) in [
    ('phone, large text, dark', const Size(360, 740), 2.0, Brightness.dark),
    ('desktop', const Size(1280, 800), 1.0, Brightness.light),
  ]) {
    testWidgets('lays out on $name', (tester) async {
      await pump(
        tester,
        avatarUrl: small,
        size: size,
        textScale: scale,
        brightness: brightness,
      );
      await tester.tap(profileAvatar());
      await tester.pumpAndSettle();

      expect(find.byType(AvatarViewer), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
