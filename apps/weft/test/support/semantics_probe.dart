import 'dart:ui' show Tristate;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The two things an accessibility test needs to look at, and neither of them
/// is a widget.
///
/// A semantics label is not on the widget tree — it is on the node tree the
/// engine builds from it, which is why [labelsIn] walks nodes rather than
/// `find.text`. An announcement is not even there: it is a message on a
/// platform channel with no node at all, which is the whole reason the app uses
/// one for things that happen off screen.
///
/// Shared because every screen's suite asks the same two questions, and the
/// version that lived in `chat_semantics_test.dart` was already the second
/// place someone would have written it.

/// Every semantics label on screen, in traversal order.
///
/// Call [WidgetTester.ensureSemantics] first, or the tree this walks is not
/// built at all and every assertion passes for the wrong reason.
List<String> labelsIn(WidgetTester tester) {
  final labels = <String>[];
  void walk(SemanticsNode node) {
    if (node.label.isNotEmpty) labels.add(node.label);
    node.visitChildren((child) {
      walk(child);
      return true;
    });
  }

  walk(_root(tester));
  return labels;
}

/// Every label whose node is a live region.
///
/// Separate from [labelsIn] because "the words are somewhere on screen" and
/// "the words will be read out when they change" are different claims, and only
/// the second one is what a live region is for.
List<String> liveRegionsIn(WidgetTester tester) {
  final labels = <String>[];
  void walk(SemanticsNode node) {
    final data = node.getSemanticsData();
    if (data.flagsCollection.isLiveRegion && data.label.isNotEmpty) {
      labels.add(data.label);
    }
    node.visitChildren((child) {
      walk(child);
      return true;
    });
  }

  walk(_root(tester));
  return labels;
}

/// Every control on screen, by the name a screen reader would give it.
///
/// A control is a node offering a tap — the same definition
/// [LabeledTapTargetGuideline] uses, and for the same reason: it is what the
/// platform's accessibility layer will let a user activate. Text fields are
/// left out because they are reached and operated differently, and links
/// because they are reached through the text they sit in.
///
/// The name falls back to the tooltip, which is where an `IconButton` puts it.
List<String> controlNamesIn(WidgetTester tester) {
  final names = <String>[];
  void walk(SemanticsNode node) {
    final data = node.getSemanticsData();
    final interactive =
        data.hasAction(SemanticsAction.tap) && !data.flagsCollection.isLink;
    final hidden =
        node.isInvisible ||
        data.flagsCollection.isHidden ||
        data.flagsCollection.isTextField ||
        // A control that says it is off is not one a keyboard has to reach.
        data.flagsCollection.isEnabled == Tristate.isFalse;
    final name = data.label.isNotEmpty ? data.label : data.tooltip;
    if (interactive && !hidden && name.isNotEmpty) names.add(name);
    node.visitChildren((child) {
      walk(child);
      return true;
    });
  }

  walk(_root(tester));
  return names;
}

/// The name of the node the framework currently reports as focused.
///
/// Read off the semantics tree rather than off [FocusManager], because the two
/// answer different questions: the focus tree knows *a node* has focus and the
/// semantics tree knows what that node is called. A control Tab lands on and a
/// control a screen reader can name are not automatically the same control —
/// which was the whole of the audit's CROSS-3.
String? focusedNameIn(WidgetTester tester) {
  String? found;
  void walk(SemanticsNode node) {
    final data = node.getSemanticsData();
    if (found == null && data.flagsCollection.isFocused == Tristate.isTrue) {
      final name = data.label.isNotEmpty ? data.label : data.tooltip;
      if (name.isNotEmpty) found = name;
    }
    node.visitChildren((child) {
      walk(child);
      return true;
    });
  }

  walk(_root(tester));
  return found;
}

/// The node tree's root, or a failure saying why there isn't one.
SemanticsNode _root(WidgetTester tester) {
  // The root owner holds no nodes of its own — the view's owner does, and it is
  // a child of it. Walking the children is what replaces the deprecated
  // `binding.pipelineOwner`.
  SemanticsNode? root;
  void search(PipelineOwner owner) {
    root ??= owner.semanticsOwner?.rootSemanticsNode;
    owner.visitChildren(search);
  }

  search(tester.binding.rootPipelineOwner);
  if (root == null) {
    fail(
      'No semantics tree — call tester.ensureSemantics() first, or every '
      'assertion below passes for the wrong reason.',
    );
  }
  return root!;
}

/// Collects everything the app sends to the platform's announcement channel.
///
/// An announcement has no widget to find, which is the whole reason it is used
/// — for a merge that removed the card the user was standing on, or a call
/// arriving over a screen that is not going anywhere, there is no node to point
/// a live region at. The channel is the only place it is observable.
List<String> watchAnnouncements(WidgetTester tester) {
  final announced = <String>[];
  tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler(
    SystemChannels.accessibility,
    (message) async {
      final map = message! as Map<Object?, Object?>;
      if (map['type'] == 'announce') {
        final data = map['data']! as Map<Object?, Object?>;
        announced.add(data['message']! as String);
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger
        .setMockDecodedMessageHandler<Object?>(
          SystemChannels.accessibility,
          null,
        ),
  );
  return announced;
}
