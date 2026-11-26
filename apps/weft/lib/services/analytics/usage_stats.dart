/// Anonymous usage statistics, and only for someone who said yes to them.
///
/// Sennit's own Plausible server (self-hosted, no cookies, no stored IP
/// addresses) is told which screens are opened and a handful of feature
/// events. What may go out is fixed here, in types rather than in strings: a
/// screen is named after the widget that draws it, never after the chat or
/// person on it, and every event detail is an enum value. There is no way to
/// pass free text, a room, a user or a message into this file.
library;

import 'package:flutter/widgets.dart';
import 'package:weft_domain/weft_domain.dart' show ChatNetwork;

/// The Plausible server and the site the events are filed under.
const String kUsageStatsServer = 'https://analytics.bostrot.com';
const String kUsageStatsDomain = 'sennit.app';

/// Sends one event. `page` is a path such as `/settings`.
typedef UsageSender =
    Future<void> Function({
      required String name,
      required String page,
      required Map<String, String> props,
    });

/// The AI features worth counting: the ones a person starts by hand.
enum AiUsage { translate, quickMessage, transcribe }

/// How Pro was bought.
enum ProPurchaseSource { store, licence }

/// Records screens and feature events, while [allowed] says so.
///
/// [allowed] is asked at every event rather than once, so switching the
/// setting off stops the next event, not the next launch.
class UsageStats {
  UsageStats({
    required this.allowed,
    required UsageSender send,
    this.props = const {},
  }) : _send = send;

  /// Whether the user opted in and nothing on the platform says otherwise.
  final bool Function() allowed;

  /// Sent with every event: the app version and the platform.
  final Map<String, String> props;

  final UsageSender _send;

  /// A screen was opened.
  void screen(String page) => _event('pageview', page: page);

  void bridgeConnected(ChatNetwork network) =>
      _event('Bridge connected', detail: {'network': network.id});

  void aiUsed(AiUsage feature) =>
      _event('AI used', detail: {'feature': feature.name});

  void deviceSyncOn() => _event('Device sync on');

  void proPurchased(ProPurchaseSource source) =>
      _event('Pro purchased', detail: {'source': source.name});

  void _event(
    String name, {
    String page = '/',
    Map<String, String> detail = const {},
  }) {
    if (!allowed()) return;
    // Statistics never get in the way: a failed send is a lost count.
    _send(
      name: name,
      page: page,
      props: {...props, ...detail},
    ).catchError((Object _) {});
  }
}

/// Reports a pageview for each screen pushed onto the navigator.
///
/// Nearly every screen in Sennit is a `MaterialPageRoute` with no name, so a
/// screen is named after the widget its route builds — `ChatView` is
/// `/chat`, `AiSettingsScreen` is `/ai-settings` — which also guarantees a
/// path never carries a room or a user. Dialogs and sheets are not screens
/// and are not counted.
class UsageStatsObserver extends NavigatorObserver {
  UsageStatsObserver(this.stats);

  final UsageStats Function() stats;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _report(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _report(newRoute);

  void _report(Route<dynamic>? route) {
    if (route is! PageRoute) return;
    // The route builds its page in the frame after the push.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final page = usageScreenName(route);
      if (page != null) stats().screen(page);
    });
  }
}

/// The path a route is reported under, or null when it cannot be told.
@visibleForTesting
String? usageScreenName(Route<dynamic> route) {
  // A route's own name is not used: the chat route's carries the chat id.
  if (route.isFirst) return '/';
  if (route is! ModalRoute) return null;
  final type = _pageType(route.subtreeContext);
  return type == null ? null : '/${_kebab(type)}';
}

/// The type name of the first widget the route's builder returned.
///
/// Below the route's subtree context sit the framework's own wrappers — a
/// `Semantics` for every page route — and then whatever the builder made.
String? _pageType(BuildContext? context) {
  if (context is! Element) return null;
  String? found;
  void visit(Element element) {
    if (found != null) return;
    final widget = element.widget;
    if (widget is Semantics || widget is Builder) {
      element.visitChildElements(visit);
      return;
    }
    found = widget.runtimeType.toString();
  }

  context.visitChildElements(visit);
  return found;
}

final _suffix = RegExp(r'(Screen|Page|View)$');
final _wordStart = RegExp('(?<=[a-z0-9])(?=[A-Z])');

/// `AiSettingsScreen` → `ai-settings`, `_PinSetup<int>` → `pin-setup`.
String _kebab(String name) {
  final bare = name
      .replaceAll(RegExp('<.*'), '')
      .replaceAll(RegExp('^_+'), '')
      .replaceAll(_suffix, '');
  return bare.split(_wordStart).join('-').toLowerCase();
}
