import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:weft_matrix/weft_matrix.dart';

import '../bridges/bridge_external_sign_in.dart';

/// Signing in to a Matrix server on its own page, in the person's browser,
/// and catching the address the page sends the browser back to.
///
/// Two ways of catching it. A phone has the system's sign-in sheet — an Auth
/// Tab or a Custom Tab on Android, `ASWebAuthenticationSession` on iOS — the
/// same one the Mattermost sign-in uses, waiting for [kOAuthRedirectScheme].
/// A desktop has no such sheet and no scheme Sennit could register without an
/// installer, so it listens on a loopback port for the one request the
/// browser makes at the end (RFC 8252 §7.3), which every OAuth server allows
/// a native app on any port.
abstract interface class BrowserLogin {
  /// Builds the page with [pageFor], from the address this way of catching
  /// the answer needs it to send the browser back to, opens it, and returns
  /// the address the browser came back to — or null when the person closed
  /// it first, or [cancel] was called.
  ///
  /// [doneText] is what a desktop browser shows once it has handed over.
  Future<Uri?> run(
    Future<Uri> Function(Uri redirectUri) pageFor, {
    required String doneText,
  });

  /// Gives up on the sign-in in progress; [run] returns null.
  void cancel();
}

final browserLoginProvider = Provider<BrowserLogin>((ref) {
  return externalSignInAvailable ? SheetBrowserLogin() : LoopbackBrowserLogin();
});

/// [BrowserLogin] on a phone: the system's sign-in sheet.
class SheetBrowserLogin implements BrowserLogin {
  SheetBrowserLogin({BrowserAuthenticate? authenticate})
    : _authenticate = authenticate ?? authenticateInBrowser;

  final BrowserAuthenticate _authenticate;

  @override
  Future<Uri?> run(
    Future<Uri> Function(Uri redirectUri) pageFor, {
    required String doneText,
  }) async {
    final page = await pageFor(kOAuthRedirectUri);
    return _authenticate(page, callbackScheme: kOAuthRedirectScheme);
  }

  /// The sheet has its own close button, and it is the only one: nothing
  /// behind it can be tapped while it is up.
  @override
  void cancel() {}
}

/// [BrowserLogin] on a desktop: the default browser and a loopback port.
class LoopbackBrowserLogin implements BrowserLogin {
  LoopbackBrowserLogin({Future<bool> Function(Uri url)? open})
    : _open = open ?? _launch;

  final Future<bool> Function(Uri url) _open;

  static Future<bool> _launch(Uri url) =>
      launchUrl(url, mode: LaunchMode.externalApplication);

  Completer<Uri?>? _pending;

  @override
  Future<Uri?> run(
    Future<Uri> Function(Uri redirectUri) pageFor, {
    required String doneText,
  }) async {
    cancel();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final pending = _pending = Completer<Uri?>();
    final redirect = Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: server.port,
      path: '/callback',
    );
    final subscription = server.listen((request) async {
      // A browser asks for a favicon too; only the redirect itself answers.
      if (request.uri.path != redirect.path) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      request.response.headers.contentType = ContentType.html;
      request.response.write(_donePage(doneText));
      await request.response.close();
      if (!pending.isCompleted) {
        pending.complete(redirect.replace(query: request.uri.query));
      }
    });
    try {
      final page = await pageFor(redirect);
      if (!await _open(page)) return null;
      // Long enough for an identity provider that wants a second factor,
      // short enough that a forgotten tab does not hold a port all day.
      return await pending.future.timeout(
        const Duration(minutes: 15),
        onTimeout: () => null,
      );
    } finally {
      if (identical(_pending, pending)) _pending = null;
      await subscription.cancel();
      await server.close(force: true);
    }
  }

  @override
  void cancel() {
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) pending.complete(null);
  }

  static String _donePage(String text) {
    final escaped = const HtmlEscape().convert(text);
    return '<!doctype html><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width">'
        '<title>Sennit</title>'
        '<body style="font-family:system-ui,sans-serif;display:grid;'
        'place-items:center;min-height:90vh;margin:0">'
        '<p style="max-width:28em;text-align:center">$escaped</p>';
  }
}
