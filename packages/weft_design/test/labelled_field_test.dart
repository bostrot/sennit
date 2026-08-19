import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_design/weft_design.dart';

/// The defect this widget exists to close was found on a device, not in a test,
/// and the reason is worth pinning: `tester.getSemantics(find.byType(TextField))`
/// walks *up* from the field's render object and returns the first node it
/// meets. When the annotation has leaked into an ancestor, that ancestor **is**
/// the node it finds — so the old shape passed every label assertion in the
/// suite while announcing the whole screen as an edit box.
///
/// These tests walk down from the root instead, and assert about the node's
/// *rect*, which is the thing that was wrong.
void main() {
  /// Every text-field node in the tree, with the box it covers.
  List<(String, Rect)> textFields(WidgetTester tester) {
    final found = <(String, Rect)>[];
    void walk(SemanticsNode node) {
      final data = node.getSemanticsData();
      if (data.flagsCollection.isTextField) {
        found.add((data.label, node.rect));
      }
      node.visitChildren((child) {
        walk(child);
        return true;
      });
    }

    SemanticsNode? root;
    void search(PipelineOwner owner) {
      root ??= owner.semanticsOwner?.rootSemanticsNode;
      owner.visitChildren(search);
    }

    search(tester.binding.rootPipelineOwner);
    walk(root!);
    return found;
  }

  /// A field at the bottom of a tall screen, which is where the leak showed:
  /// the composer is the last thing in a column whose other half is a list.
  Future<void> pumpField(WidgetTester tester, {Widget? suffix}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const Expanded(child: Center(child: Text('a long conversation'))),
              WeftLabelledField(
                label: 'Message via Signal',
                child: TextField(
                  decoration: InputDecoration(
                    hintText: 'Message via Signal',
                    suffixIcon: suffix,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  testWidgets('is named, and no bigger than the field', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpField(tester);

    final fields = textFields(tester);
    expect(fields.map((field) => field.$1), contains('Message via Signal'));

    // The claim that matters: every text-field node covers the field, not the
    // screen. The leaked node was the whole body.
    final box = tester.getRect(find.byType(TextField));
    for (final (label, rect) in fields) {
      expect(rect.height, lessThanOrEqualTo(box.height + 1), reason: label);
    }
    handle.dispose();
  });

  testWidgets('keeps the label after typing', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpField(tester);

    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();

    // The whole point of the annotation: a hint is gone at the first
    // keystroke, and the field would otherwise be called nothing.
    expect(
      textFields(tester).map((field) => field.$1),
      contains('Message via Signal'),
    );
    handle.dispose();
  });

  testWidgets('does not swallow a control inside the decoration', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpField(
      tester,
      suffix: IconButton(
        tooltip: 'Clear search',
        icon: const Icon(Icons.close_rounded),
        onPressed: () {},
      ),
    );

    // Two of the seven fields this wraps carry a button in their
    // `suffixIcon` — clear-search, change-server. A wrapper that merged the
    // decoration into the field would take those buttons off the tree
    // entirely, which is a worse bug than the one being fixed.
    final button = tester
        .getSemantics(find.byTooltip('Clear search'))
        .getSemanticsData();
    expect(button.tooltip, 'Clear search');
    expect(button.hasAction(SemanticsAction.tap), isTrue);
    // And it is not the field's node wearing the button's tooltip.
    expect(button.flagsCollection.isTextField, isFalse);
    handle.dispose();
  });
}
