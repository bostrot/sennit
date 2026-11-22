import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:weft_bridges/weft_bridges.dart';
import 'package:weft_design/weft_design.dart';

import '../../app/localisation.dart';

/// Opens a network's own sign-in page and returns what the bridge asked for.
///
/// Null when the person closed the page before getting in.
typedef BrowserSignIn =
    Future<Map<String, String>?> Function(
      BuildContext context,
      LoginCookiesParams params,
      String networkName,
    );

/// Whether this platform can show the sign-in page at all.
///
/// The web view runs on phones and macOS. Windows would need the WebView2
/// runtime, and Linux has no implementation, so those keep the "needs a web
/// browser" screen.
bool get browserSignInAvailable {
  if (kIsWeb) return false;
  return Platform.isAndroid || Platform.isIOS || Platform.isMacOS;
}

/// The real [BrowserSignIn]: a full-screen page with the network's site.
Future<Map<String, String>?> openBrowserSignIn(
  BuildContext context,
  LoginCookiesParams params,
  String networkName,
) => Navigator.of(context).push<Map<String, String>>(
  MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) =>
        BridgeBrowserSignInPage(params: params, networkName: networkName),
  ),
);

/// Instagram's, Messenger's or any other network's own login page, inside
/// Sennit.
///
/// Some bridges sign in by taking over a web session: the person signs in on
/// the network's site as they would in any browser, and the bridge is handed
/// the cookies that session left behind. Sennit never reads what is typed
/// into the page; it waits for the address the bridge said means "signed in"
/// ([LoginCookiesParams.waitForUrlPattern]), reads the named cookies from the
/// web view's own store — which, unlike a page script, can see HttpOnly ones
/// like Instagram's `sessionid` — and then deletes every cookie the page left,
/// so the session lives only in the bridge.
class BridgeBrowserSignInPage extends StatefulWidget {
  const BridgeBrowserSignInPage({
    super.key,
    required this.params,
    required this.networkName,
  });

  final LoginCookiesParams params;
  final String networkName;

  @override
  State<BridgeBrowserSignInPage> createState() =>
      _BridgeBrowserSignInPageState();
}

class _BridgeBrowserSignInPageState extends State<BridgeBrowserSignInPage> {
  final _cookies = CookieManager.instance();
  double _progress = 0;
  bool _harvesting = false;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    // A session from an earlier, abandoned attempt would sign the page in
    // as whoever that was.
    unawaited(_cookies.deleteAllCookies());
  }

  @override
  void dispose() {
    unawaited(_cookies.deleteAllCookies());
    super.dispose();
  }

  /// The sites whose cookies the bridge wants: the page's own, and every
  /// domain a field names.
  ///
  /// The page is also asked as it is, scheme, port and path included: a
  /// self-hosted server — Mattermost on plain http, on its own port or under
  /// `/mattermost` — scopes its cookies to exactly that, and the store only
  /// hands a cookie to an address its path and security match.
  List<WebUri> get _cookieUrls {
    final page = Uri.parse(widget.params.url);
    final domains = {
      page.host,
      for (final field in widget.params.fields)
        for (final source in field.sources) ?source.cookieDomain,
    };
    return [
      WebUri(
        Uri(
          scheme: page.scheme,
          host: page.host,
          port: page.hasPort ? page.port : null,
          path: page.path,
        ).toString(),
      ),
      for (final domain in domains) ...[
        WebUri('https://$domain/'),
        if (!domain.startsWith('www.')) WebUri('https://www.$domain/'),
      ],
    ];
  }

  Future<void> _check(InAppWebViewController controller, WebUri? url) async {
    if (_harvesting || _done || url == null) return;
    final params = widget.params;
    // With a pattern, only the page it names is the finish line; without
    // one, any page where everything required is present.
    if (params.waitForUrlPattern != null && !params.isDone(url.toString())) {
      return;
    }
    _harvesting = true;
    try {
      final cookies = <String, String>{};
      for (final site in _cookieUrls) {
        for (final cookie in await _cookies.getCookies(url: site)) {
          final value = cookie.value?.toString();
          if (value != null && value.isNotEmpty) cookies[cookie.name] = value;
        }
      }
      final storage = <String, String>{};
      for (final key in params.localStorageKeys) {
        final value = await controller.evaluateJavascript(
          source: 'window.localStorage.getItem(${_jsString(key)})',
        );
        if (value is String && value.isNotEmpty) storage[key] = value;
      }
      final values = params.collect(cookies, localStorage: storage);
      if (values == null || !mounted) return;
      _done = true;
      Navigator.of(context).pop(values);
    } finally {
      _harvesting = false;
    }
  }

  static String _jsString(String value) =>
      "'${value.replaceAll(r'\', r'\\').replaceAll("'", r"\'")}'";

  @override
  Widget build(BuildContext context) {
    final params = widget.params;
    return Scaffold(
      appBar: WeftAppBar(
        title: Text(context.l10n.botLoginTitle(widget.networkName)),
        leading: CloseButton(onPressed: () => Navigator.of(context).pop()),
        bottom: _progress < 1
            ? PreferredSize(
                preferredSize: const Size.fromHeight(2),
                child: LinearProgressIndicator(
                  value: _progress == 0 ? null : _progress,
                  minHeight: 2,
                ),
              )
            : null,
      ),
      body: InAppWebView(
        initialUrlRequest: URLRequest(url: WebUri(params.url)),
        initialSettings: InAppWebViewSettings(
          userAgent: params.userAgent,
          // Nothing from this page belongs in a cache that outlives it.
          cacheEnabled: false,
          clearCache: true,
          thirdPartyCookiesEnabled: true,
          sharedCookiesEnabled: false,
        ),
        onProgressChanged: (_, progress) {
          if (mounted) setState(() => _progress = progress / 100);
        },
        onLoadStop: _check,
        onUpdateVisitedHistory: (controller, url, _) => _check(controller, url),
      ),
    );
  }
}
