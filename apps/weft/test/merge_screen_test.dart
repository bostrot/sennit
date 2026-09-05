import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/providers.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft/features/merge/merge_screen.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft/app/localisation.dart';

void main() {
  Future<DemoChatRepository> pump(WidgetTester tester) async {
    final repository = DemoChatRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [chatRepositoryProvider.overrideWithValue(repository)],
        child: MaterialApp(
          localizationsDelegates: weftLocalizationsDelegates,
          theme: WeftTheme.build(),
          home: const MergeScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return repository;
  }

  testWidgets('shows the scorer suggestion with its evidence', (tester) async {
    await pump(tester);

    // The demo fixtures include Michael on WhatsApp and Discord with a
    // near-identical name and matching avatar — the scorer should propose it.
    expect(find.text('Michael Johnson'), findsWidgets);
    expect(find.text('Identical name'), findsOneWidget);
    expect(find.text('Nearly identical avatar'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Merge'), findsOneWidget);

    // Anna is already merged: her card shows the contact name plus one row
    // per handle that shares it.
    expect(find.text('Anna Maven'), findsWidgets);
    expect(
      find.text('Unmerge'),
      findsNWidgets(3),
      reason: 'one per leg of the three-network Anna merge',
    );
  });

  testWidgets('merging moves the pair from suggestions to merged', (
    tester,
  ) async {
    final repository = await pump(tester);

    await tester.tap(find.widgetWithText(FilledButton, 'Merge'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FilledButton, 'Merge'), findsNothing);
    expect(
      repository.identityGraph.contacts().where((c) => c.isMerged),
      hasLength(2),
      reason: 'Anna (fixture) plus the newly merged Michael',
    );
  });

  testWidgets('rejecting a suggestion removes it and it stays gone', (
    tester,
  ) async {
    final repository = await pump(tester);

    await tester.tap(find.text('Not the same person'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FilledButton, 'Merge'), findsNothing);
    expect(
      repository.identityGraph.suggestions(),
      isEmpty,
      reason: 'a dismissal is a sticky decision, not a snooze',
    );
  });

  testWidgets('unmerging splits a handle out', (tester) async {
    final repository = await pump(tester);

    final before = repository.identityGraph
        .contacts()
        .where((c) => c.isMerged)
        .length;
    await tester.tap(find.text('Unmerge').first);
    await tester.pumpAndSettle();

    final anna = repository.identityGraph.contacts().where(
      (c) => c.displayName.contains('Anna'),
    );
    expect(
      anna.every((c) => c.handles.length < 3),
      isTrue,
      reason: 'one of Anna\'s three legs should have been split out',
    );
    expect(
      repository.identityGraph.contacts().where((c) => c.isMerged).length,
      before,
      reason: 'Anna keeps two legs, so she is still merged',
    );
  });
}
