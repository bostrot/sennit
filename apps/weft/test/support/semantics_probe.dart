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

/// Every control a screen reader would announce as nothing.
///
/// The inverse of [controlNamesIn], and deliberately the same definition of a
/// control so the two partition the same set: a node offering a tap, not a
/// link, not hidden, not a text field. An icon-only button with neither a
/// `Semantics` label nor a tooltip lands here — which is the register the route
/// walk's audit reports — and so does any other silent tappable, which is the
/// right generalisation. A widget-type check for `IconButton` would miss the
/// `InkWell` around two glyphs, and that is where these actually come from.
///
/// `value` counts as a name: a chip whose visible content is its own label
/// needs no annotation on top of it.
///
/// Each entry is the node's size, because a silent control has nothing else to
/// identify it by — which is the whole finding.
List<String> unnamedControlsIn(WidgetTester tester) {
  final found = <String>[];
  void walk(SemanticsNode node) {
    final data = node.getSemanticsData();
    final named =
        data.label.isNotEmpty ||
        data.tooltip.isNotEmpty ||
        data.value.isNotEmpty;
    final hidden =
        node.isInvisible ||
        // A merged node is not one a reader ever lands on — its label, its
        // actions and its flags all belong to the ancestor that absorbed it,
        // and that ancestor is what gets checked. Without this every
        // `SwitchListTile` in settings reports its switch as an unnamed 60×40
        // control, which is Material's own structure and not a defect.
        // `MinimumTapTargetGuideline` skips them for the same reason.
        node.isMergedIntoParent ||
        data.flagsCollection.isHidden ||
        data.flagsCollection.isTextField ||
        data.flagsCollection.isLink;
    if (data.hasAction(SemanticsAction.tap) && !named && !hidden) {
      found.add('${node.rect.width.round()}×${node.rect.height.round()}');
    }
    node.visitChildren((child) {
      walk(child);
      return true;
    });
  }

  walk(_root(tester));
  return found;
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

/// Every control bigger than [maxHeight], described well enough to find it.
///
/// A control the size of the screen is not a design decision, it is an
/// annotation that has merged into an ancestor. `Semantics(…)` with the default
/// `container: false` does not make a node — it adds its label and its flags to
/// the nearest *enclosing* node, and when the thing it wraps paints no
/// semantics of its own (a chip whose only content is two silent glyphs) or
/// sits alone at the bottom of a screen, that enclosing node is the screen.
///
/// TalkBack found the first of these on a device: the chat view exported the
/// whole conversation as one edit box named after the composer. No assertion in
/// the suite could see it, because the natural way to check a field's name is
/// `tester.getSemantics(find.byType(TextField))` — and that walks *up* from the
/// render object to the first node it meets, which when the label has leaked
/// **is** the leaked node. So the check passed on the strength of the bug.
/// This one starts at the root, walks down, and looks at rects.
///
/// A control is a node offering a tap or holding text, which is what makes the
/// scroll view enclosing a list — properly the size of the screen — not one.
List<String> oversizedControlsIn(
  WidgetTester tester, {
  required double maxHeight,
}) {
  final found = <String>[];
  void walk(SemanticsNode node) {
    final data = node.getSemanticsData();
    final control =
        data.hasAction(SemanticsAction.tap) || data.flagsCollection.isTextField;
    if (control && node.rect.height > maxHeight) {
      final name = [
        data.label,
        data.tooltip,
      ].firstWhere((part) => part.isNotEmpty, orElse: () => '<unnamed>');
      found.add(
        '"$name" is ${node.rect.width.round()}×${node.rect.height.round()}',
      );
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
