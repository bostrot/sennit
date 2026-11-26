import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'model_transport.dart';

/// Hands the download to the operating system so it survives the app going
/// away.
///
/// On Android that means a foreground service, which is *why* there is a
/// notification: the notification is not decoration, it is the price of being
/// allowed to keep working in the background. On iOS a background URLSession
/// continues while the app is suspended and wakes it when the file lands.
///
/// Either way the user can leave, lock the phone, and come back to a finished
/// model instead of a download that silently died at 60%.
class BackgroundModelDownloadTransport implements ModelDownloadTransport {
  BackgroundModelDownloadTransport({ModelDownloadTransport? fallback})
    : _fallback = fallback ?? HttpModelDownloadTransport();

  /// Used on desktop and for any target the plugin cannot address — it insists
  /// on paths relative to a known base directory, because the OS download
  /// services do too.
  final ModelDownloadTransport _fallback;

  bool _configured = false;

  /// Only mobile is handled natively. A desktop process simply keeps running,
  /// so the plain HTTP path there is both simpler and better behaved.
  static bool get isSupportedHere => Platform.isAndroid || Platform.isIOS;

  Future<void> _configure() async {
    if (_configured) return;
    _configured = true;

    FileDownloader().configureNotification(
      running: const TaskNotification(
        '{displayName}',
        'Downloading — {progress}. Safe to leave the app.',
      ),
      complete: const TaskNotification('{displayName}', 'Download finished'),
      error: const TaskNotification('{displayName}', 'Download failed'),
      paused: const TaskNotification('{displayName}', 'Paused — will resume'),
      progressBar: true,
    );

    // Asked for here rather than at startup: this is the first moment the
    // permission does something for the user. A refusal is not fatal — the
    // download still runs, Android just cannot show its progress.
    try {
      final status = await FileDownloader().permissions.status(
        PermissionType.notifications,
      );
      if (status == PermissionStatus.undetermined) {
        await FileDownloader().permissions.request(
          PermissionType.notifications,
        );
      }
    } catch (error) {
      debugPrint('Notification permission request failed: $error');
    }
  }

  @override
  Future<void> download({
    required Uri url,
    required File target,
    required int expectedBytes,
    required String displayName,
    Map<String, String> headers = const {},
    void Function(int totalOnDisk)? onBytes,
    Future<bool> Function()? shouldContinue,
    bool requiresWiFi = false,
  }) async {
    if (!isSupportedHere) {
      return _fallback.download(
        url: url,
        target: target,
        expectedBytes: expectedBytes,
        displayName: displayName,
        headers: headers,
        onBytes: onBytes,
        shouldContinue: shouldContinue,
      );
    }

    final support = await getApplicationSupportDirectory();
    if (!p.isWithin(support.path, target.path)) {
      return _fallback.download(
        url: url,
        target: target,
        expectedBytes: expectedBytes,
        displayName: displayName,
        headers: headers,
        onBytes: onBytes,
        shouldContinue: shouldContinue,
      );
    }

    await _configure();

    final task = DownloadTask(
      url: url.toString(),
      filename: p.basename(target.path),
      directory: p.relative(target.parent.path, from: support.path),
      baseDirectory: BaseDirectory.applicationSupport,
      headers: headers,
      displayName: displayName,
      updates: Updates.statusAndProgress,
      allowPause: true,
      retries: 3,
      // Waits, rather than fails, while the phone is on mobile data.
      requiresWiFi: requiresWiFi,
    );

    // The plugin owns the transfer, so cancellation cannot be a check inside a
    // byte loop — it has to be a message sent to the native side.
    var cancelling = false;
    Timer? watchdog;
    if (shouldContinue != null) {
      watchdog = Timer.periodic(const Duration(milliseconds: 500), (_) async {
        if (cancelling || await shouldContinue()) return;
        cancelling = true;
        await FileDownloader().cancelTaskWithId(task.taskId);
      });
    }

    try {
      final result = await FileDownloader().download(
        task,
        onProgress: (fraction) {
          // Negative values are the plugin's way of signalling waiting,
          // failed and paused states rather than any amount of progress.
          if (fraction < 0 || expectedBytes <= 0) return;
          onBytes?.call((fraction * expectedBytes).round());
        },
      );

      switch (result.status) {
        case TaskStatus.complete:
          return;
        case TaskStatus.canceled:
          throw const DownloadCancelled();
        case TaskStatus.notFound:
          throw DownloadFailure('$displayName is no longer available (404)');
        default:
          throw DownloadFailure(
            result.exception?.description ??
                '$displayName failed (${result.status.name})',
          );
      }
    } finally {
      watchdog?.cancel();
    }
  }

  @override
  void dispose() => _fallback.dispose();
}
