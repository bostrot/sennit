import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_design/weft_design.dart';

import 'semantics_probe.dart';

/// The four mechanical questions the route walk asks of every surface it
/// reaches, and the one type it answers them in.
///
/// Deliberately *findings* rather than assertions. A guideline sweep
/// (`test/a11y/semantics_test.dart`) answers pass or fail over six screens; the
/// walk visits forty-five and its output is a work list — `file:line`, what is
/// wrong, what it should be — which means each scanner has to hand back a list
/// rather than call `fail`. The walk decides which categories are fatal.
///
/// Three of the four are cheap restatements of things Flutter or this repo
/// already owns, and they are restated here for that reason only:
///
///  * **exceptions** — `RenderFlex overflowed` is *reported*, not thrown, so
///    nothing on the assertion path sees it. [ExceptionRecorder] catches the
///    report.
///  * **tap targets** — the same traversal as `MinimumTapTargetGuideline`,
///    down to the scrollable-boundary skip, returning the offenders instead of
///    an `Evaluation`. The thresholds are `weft_design`'s own (see
///    [minimumTapTargetFor]), not the guideline's.
///  * **unnamed controls** — the same definition as `labeledTapTargetGuideline`.
///  * **off-scale spacing** — [offScaleSpacingIn], which nothing else does.

/// One thing wrong on one surface.
@immutable
class UiFinding {
  const UiFinding({
    required this.surface,
    required this.category,
    required this.detail,
    this.where,
  });

  /// The route-walk label of the screen this was found on.
  final String surface;

  /// `overflow`, `exception`, `tap-target`, `unnamed`, or `off-scale`.
  final String category;

  /// What is wrong, in one line.
  final String detail;

  /// The widget chain it sits in, nearest-last — enough to find it in the
  /// source. Null where the finding is not attached to a widget.
  final String? where;

  @override
  String toString() =>
      '[$category] $surface: $detail${where == null ? '' : '  ($where)'}';
}

/// The smallest a control may be on [surface] before it is a finding.
///
/// Touch is [kWeftMinTapTarget], `weft_design`'s own 48 — Android's guideline,
/// the stricter of the two Sennit ships against, and the one the accessibility
/// suite already asserts.
///
/// The pointer surface is **24**, and deliberately not
/// [kWeftMinPointerTarget]. That constant is 28 and it is a *sizing* token —
/// how big a dense desktop control should be drawn — rather than a floor. Read
/// as a floor it fails `MacPushButton`, which is 24 tall on purpose because a
/// Mac's default button is 22; the walk then reported thirty-nine findings
/// that were all one deliberate decision, and buried the six controls that are
/// genuinely too small to hit. 24 is WCAG 2.5.8's minimum target size, which is
/// the question actually being asked here — can this be *hit* — and it leaves
/// the platform's own button exactly on the line rather than a hair under it.
///
/// The disagreement between the two numbers is itself recorded in
/// `docs/quality/ui-audit.md`; this function picks the one that makes the
/// report readable, it does not settle it.
const double kWeftPointerTargetFloor = 24;

double minimumTapTargetFor(WeftSurface surface) =>
    surface == WeftSurface.mac ? kWeftPointerTargetFloor : kWeftMinTapTarget;

/// The spacing scale, as numbers.
///
/// Zero is on it: `SizedBox.shrink()` and a zero edge are the absence of a gap,
/// not an arbitrary one. Everything else must be a [WeftSpace] constant.
///
/// Not `const`: a constant set may not hold `double`s, because the analyzer
/// will not vouch for their `==`. The values are compile-time constants either
/// way.
final Set<double> weftSpaceScale = {
  0,
  WeftSpace.xxs,
  WeftSpace.xs,
  WeftSpace.dense,
  WeftSpace.sm,
  WeftSpace.md,
  WeftSpace.lg,
  WeftSpace.xl,
  WeftSpace.xxl,
  WeftSpace.huge,
};

/// Lengths that are a platform *metric* rather than a gap, and the same
/// lengths plus one spacing token.
///
/// Three sites in the Mac chrome inset by a number the system dictates: the
/// toolbar's own height, so a list can scroll under it and show through its
/// glass; and the traffic-light clearance, so no control sits under the close
/// button. `MacToolbar` writes the second as `leadingInset + WeftSpace.md`,
/// which is two tokens added together and resolves to a 90 this scan would
/// otherwise report as an arbitrary double — the scanner sees the sum, never
/// the expression.
///
/// So the rule this encodes is: *a platform metric, optionally plus one
/// spacing step, is a clearance and not a gap.* It is a real exemption rather
/// than an allowlist of numbers somebody once saw, and anything genuinely
/// arbitrary still lands in the report.
final Set<double> weftLayoutMetrics = {
  for (final metric in const [
    MacMetrics.toolbarHeight,
    MacMetrics.trafficLightInset,
    MacMetrics.sidebarRowHeight,
    MacMetrics.controlSize,
    MacMetrics.fieldHeight,
    MacMetrics.menuItemHeight,
  ]) ...[
    metric,
    for (final space in [
      WeftSpace.xxs,
      WeftSpace.xs,
      WeftSpace.sm,
      WeftSpace.md,
      WeftSpace.lg,
      WeftSpace.xl,
    ])
      metric + space,
  ],
};

/// The name of the token [value] is, or null if it is not one.
String? weftSpaceName(double value) => switch (value) {
  0 => 'none',
  WeftSpace.xxs => 'WeftSpace.xxs',
  WeftSpace.xs => 'WeftSpace.xs',
  WeftSpace.dense => 'WeftSpace.dense',
  WeftSpace.sm => 'WeftSpace.sm',
  WeftSpace.md => 'WeftSpace.md',
  WeftSpace.lg => 'WeftSpace.lg',
  WeftSpace.xl => 'WeftSpace.xl',
  WeftSpace.xxl => 'WeftSpace.xxl',
  WeftSpace.huge => 'WeftSpace.huge',
  _ => null,
};

/// The token a reviewer should reach for instead of [value] — the nearest step
/// on the scale, with the distance stated so an honest "the scale has no step
/// here" is visible rather than hidden behind a rounding.
String nearestToken(double value) {
  var best = 0.0;
  var bestDelta = double.infinity;
  for (final step in weftSpaceScale) {
    final delta = (step - value).abs();
    if (delta < bestDelta) {
      bestDelta = delta;
      best = step;
    }
  }
  return '${weftSpaceName(best)} ($best, ${bestDelta > 0 ? '±$bestDelta' : 'exact'})';
}

// ------------------------------------------------------------------ exceptions

/// Everything the framework reported while a walk step ran.
///
/// A `RenderFlex overflowed` is a `FlutterError.reportError`, not a throw: the
/// widget paints its yellow-and-black stripes and layout carries on. Under a
/// live binding the report goes to the console and the test passes, which is
/// exactly how an overflow reaches a release build. Installed around each step
/// so a finding can name the surface that produced it.
///
/// Reports are *captured* rather than forwarded. Forwarding would fail the run
/// with the framework's own message, which says which `RenderFlex` and not
/// which screen — and the walk's whole value is the second half.
class ExceptionRecorder {
  ExceptionRecorder() {
    _previous = FlutterError.onError;
    FlutterError.onError = (details) => _errors.add(details);
  }

  late final FlutterExceptionHandler? _previous;
  final List<FlutterErrorDetails> _errors = [];

  /// Stops recording and hands back what was seen.
  List<FlutterErrorDetails> stop() {
    FlutterError.onError = _previous;
    return List.unmodifiable(_errors);
  }

  /// Everything recorded so far, as findings against [surface].
  ///
  /// An overflow is split out from the rest because it is the finding this
  /// harness exists for and a reader should not have to grep a stack trace to
  /// see that it happened.
  List<UiFinding> findingsFor(String surface) => [
    for (final error in _errors)
      UiFinding(
        surface: surface,
        category: _isOverflow(error) ? 'overflow' : 'exception',
        detail: _firstLine(error),
      ),
  ];

  static bool _isOverflow(FlutterErrorDetails details) =>
      details.exception is FlutterError &&
      '${details.exception}'.contains('overflowed by');

  static String _firstLine(FlutterErrorDetails details) {
    final text = '${details.exception}'.split('\n').first.trim();
    return text.length > 200 ? '${text.substring(0, 200)}…' : text;
  }
}

// ----------------------------------------------------------------- tap targets

/// Every control smaller than [minSize] on either axis.
///
/// The traversal is `MinimumTapTargetGuideline`'s, including the two skips that
/// make it usable: a node touching the edge of a scrollable is ignored (it may
/// be half scrolled away rather than small), and so is one touching the edge of
/// the view. Reimplemented rather than called because the guideline returns an
/// `Evaluation` — a pass, or one string with every failure concatenated into it
/// — and the audit report needs the offenders as rows.
///
/// Call [WidgetTester.ensureSemantics] first. Without it there is no node tree
/// and this returns an empty list, which reads exactly like a clean screen.
List<UiFinding> smallTapTargetsIn(
  WidgetTester tester, {
  required String surface,
  required double minSize,
}) {
  final found = <UiFinding>[];

  void walk(ui.FlutterView view, SemanticsNode node) {
    node.visitChildren((child) {
      walk(view, child);
      return true;
    });
    if (node.isMergedIntoParent) return;

    final data = node.getSemanticsData();
    final tappable =
        data.hasAction(SemanticsAction.tap) ||
        data.hasAction(SemanticsAction.longPress);
    if (!tappable || data.flagsCollection.isHidden) return;
    // Links are reached through the text they sit in, which is why WCAG
    // exempts them and why the guideline does too.
    if (data.flagsCollection.isLink) return;

    var bounds = node.rect;
    SemanticsNode? current = node;
    while (current != null) {
      final transform = current.transform;
      if (transform != null) {
        bounds = MatrixUtils.transformRect(transform, bounds);
      }
      if (current.flagsCollection.hasImplicitScrolling &&
          _atBoundary(bounds, current.rect)) {
        return;
      }
      current = current.parent;
    }
    if (_atBoundary(bounds, Offset.zero & view.physicalSize)) return;

    final size = bounds.size / view.devicePixelRatio;
    if (size.width >= minSize - 0.001 && size.height >= minSize - 0.001) return;

    final name = data.label.isNotEmpty
        ? data.label
        : (data.tooltip.isNotEmpty ? data.tooltip : '<unnamed>');
    found.add(
      UiFinding(
        surface: surface,
        category: 'tap-target',
        detail:
            '"$name" is ${size.width.toStringAsFixed(1)}×'
            '${size.height.toStringAsFixed(1)}, below ${minSize.toInt()}',
      ),
    );
  }

  for (final view in tester.binding.renderViews) {
    final root = view.owner?.semanticsOwner?.rootSemanticsNode;
    if (root != null) walk(view.flutterView, root);
  }
  return found;
}

/// The guideline's own boundary test: a rect flush against its container may be
/// clipped rather than small.
bool _atBoundary(Rect child, Rect parent) =>
    child.left - parent.left <= 0.001 ||
    parent.right - child.right <= 0.001 ||
    child.top - parent.top <= 0.001 ||
    parent.bottom - child.bottom <= 0.001;

// ------------------------------------------------------------ unnamed controls

/// [unnamedControlsIn]'s answer, as findings against [surface].
///
/// The walk itself lives in `semantics_probe.dart` beside the other four
/// semantics walks, because that is where a question about the node tree
/// belongs and because a second copy of the traversal would drift from
/// `controlNamesIn`, whose set this one is the complement of.
List<UiFinding> unnamedControlFindings(
  WidgetTester tester, {
  required String surface,
}) => [
  for (final size in unnamedControlsIn(tester))
    UiFinding(
      surface: surface,
      category: 'unnamed',
      detail: 'a tappable $size node with no label, tooltip or value',
    ),
];

// ------------------------------------------------------------- off-scale gaps

/// Every gap on screen that is not a [WeftSpace] token.
///
/// Two shapes, which between them are how Sennit states a gap:
///
///  * a childless `SizedBox` that is a direct child of a `Row` or `Column` —
///    the `const SizedBox(width: WeftSpace.sm)` spacer idiom. Restricted to
///    `Flex` children on purpose: a `SizedBox` anywhere else is a *size* (a
///    120pt search field, a 20pt spinner), and sizes are not on the spacing
///    scale and should not be.
///  * a `Padding`, a `Container` or an `AnimatedContainer`, on all four
///    resolved edges. `EdgeInsetsDirectional` is resolved against the subtree's
///    own direction, so a mirrored run reports the same numbers rather than
///    swapping start and end.
///
/// The two containers are named explicitly and are not redundant with
/// `Padding`. A `Container` with a `padding` builds one internally, but that
/// `Padding` is created inside `container.dart` — the local-creation filter
/// below sees Flutter as its author and drops it. Scanning only `Padding`
/// therefore missed every inset written as `Container(padding: …)`, which in
/// this tree is where several of them live.
///
/// There is no `Gap` widget in this tree — the package is not a dependency and
/// the spacer idiom above is what the app uses instead — so the third shape the
/// phase names has nothing to scan.
///
/// **Only widgets created in this repository are looked at.** Material builds
/// hundreds of `Padding`s of its own with numbers that are Material's business,
/// and a report that listed them would be unreadable and unactionable.
/// [debugIsWidgetLocalCreation] is the filter, which needs
/// `--track-widget-creation` — on for every debug build and every `flutter
/// test`, off in release. [spacingScanAvailable] says whether it is on, and the
/// walk logs a skip rather than reporting a clean screen it never looked at.
///
/// The filter is coarser than "this repository": with no pub-root directories
/// configured it means *not `packages/flutter/`*, so a widget built by a pub
/// dependency reads as local. There is no public API for the creation location
/// itself, so the report cannot say which — a finding whose chain names no
/// Sennit widget is the shape that takes.
List<UiFinding> offScaleSpacingIn(
  WidgetTester tester, {
  required String surface,
}) {
  final found = <UiFinding>[];
  final seen = <String>{};

  void report(Element element, String what, double value) {
    final where = _chainOf(element);
    // One row per call site, not per instance: a spacer inside a list builder
    // is one mistake in one file however many rows are on screen.
    final key = '$what|$value|$where';
    if (!seen.add(key)) return;
    found.add(
      UiFinding(
        surface: surface,
        category: 'off-scale',
        detail: '$what is $value — nearest token ${nearestToken(value)}',
        where: where,
      ),
    );
  }

  for (final element in tester.allElements) {
    final widget = element.widget;
    if (!debugIsWidgetLocalCreation(widget)) continue;

    if (widget is SizedBox && widget.child == null) {
      if (!_isFlexChild(element)) continue;
      for (final (axis, value) in [
        ('width', widget.width),
        ('height', widget.height),
      ]) {
        if (value == null || !_isGap(value)) continue;
        report(element, 'SizedBox $axis', value);
      }
      continue;
    }

    final padding = switch (widget) {
      Padding(:final padding) => padding,
      Container(:final padding) => padding,
      AnimatedContainer(:final padding) => padding,
      _ => null,
    };
    if (padding == null) continue;

    final direction = Directionality.maybeOf(element) ?? TextDirection.ltr;
    final insets = padding.resolve(direction);
    final what = widget.runtimeType.toString();
    for (final (edge, value) in [
      ('left', insets.left),
      ('top', insets.top),
      ('right', insets.right),
      ('bottom', insets.bottom),
    ]) {
      if (!_isGap(value)) continue;
      report(element, '$what $edge', value);
    }
  }
  return found;
}

/// Whether [offScaleSpacingIn] can see anything at all.
///
/// False in a release build, where creation locations are stripped and every
/// widget would read as somebody else's. Checked rather than assumed so a
/// profile run reports "not scanned" instead of "nothing found".
bool get spacingScanAvailable =>
    WidgetInspectorService.instance.isWidgetCreationTracked();

/// Whether [value] is a gap that should have been a token.
///
/// Three exemptions, and each one is a category rather than a number.
///
///  * It is already on the scale, or zero — the absence of a gap.
///  * It is a [weftLayoutMetrics] clearance.
///  * **It is fractional.** Every gap in this tree is written as a literal on
///    the grid; a fraction is always something *derived* — an avatar's ring is
///    `size * 0.055`, a badge's border is a proportion of its extent. Those are
///    stroke widths that happen to be expressed as padding, they scale with the
///    thing they surround, and rounding them to 2 would be a visual change with
///    no reader to benefit from it. Reporting them buried the real findings
///    forty to one.
bool _isGap(double value) =>
    value.isFinite &&
    value == value.roundToDouble() &&
    !weftSpaceScale.contains(value) &&
    !weftLayoutMetrics.contains(value);

/// Whether [element]'s immediate widget parent is a `Row` or a `Column`.
bool _isFlexChild(Element element) {
  var isFlex = false;
  element.visitAncestorElements((ancestor) {
    isFlex = ancestor.widget is Flex;
    return false; // the first ancestor only
  });
  return isFlex;
}

/// The nearest few enclosing widgets, outermost first — enough to find the call
/// site in the source without a creation location, which is private API.
///
/// Framework wrappers are skipped: a chain of `Padding › Semantics › Builder ›
/// Column` names nothing. What is kept is the first five locally-created
/// ancestors whose type is not one of the handful of structural widgets every
/// screen is made of — five rather than three because three stopped inside
/// `weft_design`'s own primitives (`WeftFocusable › FocusableActionDetector ›
/// GestureDetector`) on exactly the findings that needed a feature's name.
String _chainOf(Element element) {
  const structural = {
    'Padding',
    'SizedBox',
    'Row',
    'Column',
    'Flex',
    'Center',
    'Align',
    'Expanded',
    'Flexible',
    'Builder',
    'Consumer',
    'Semantics',
    'MergeSemantics',
    'ExcludeSemantics',
    'DefaultTextStyle',
    'IconTheme',
    'Directionality',
  };
  final chain = <String>[];
  element.visitAncestorElements((ancestor) {
    final name = ancestor.widget.runtimeType.toString();
    if (debugIsWidgetLocalCreation(ancestor.widget) &&
        !structural.contains(name) &&
        !name.startsWith('_Inherited')) {
      chain.add(name);
    }
    return chain.length < 5;
  });
  return '${chain.reversed.join(' › ')} › ${element.widget.runtimeType}';
}

// ------------------------------------------------------------------- reporting

/// The findings, grouped by category, as a block a human reads in a CI log.
String describeFindings(List<UiFinding> findings) {
  if (findings.isEmpty) return 'no findings';
  final byCategory = <String, List<UiFinding>>{};
  for (final finding in findings) {
    byCategory.putIfAbsent(finding.category, () => []).add(finding);
  }
  final buffer = StringBuffer();
  for (final entry in byCategory.entries) {
    buffer.writeln('${entry.key} (${entry.value.length}):');
    for (final finding in entry.value) {
      buffer.writeln('  ${finding.surface}: ${finding.detail}');
      if (finding.where != null) buffer.writeln('      ${finding.where}');
    }
  }
  return buffer.toString();
}

/// The findings as tab-separated rows, for pasting into `docs/quality/ui-audit.md`.
String findingsAsTsv(List<UiFinding> findings) => [
  'category\tsurface\tdetail\twhere',
  for (final f in findings)
    '${f.category}\t${f.surface}\t${f.detail}\t${f.where ?? ''}',
].join('\n');
