import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_attachments/weft_attachments.dart';

import '../../app/localisation.dart';
import '../notifications/notification_channels.dart';
import '../notifications/notification_presentation.dart';

/// What the background-work notification says right now.
@immutable
class BackgroundWorkStatus {
  const BackgroundWorkStatus({
    required this.title,
    this.detail,
    this.fraction,
    this.others = 0,
  });

  /// The job the notification is about: the oldest one still running.
  final String title;

  /// A second line, e.g. how far through a restore is. Null for none.
  final String? detail;

  /// 0..1, or null when the job cannot say how far along it is — which the
  /// notification shows as an indeterminate bar rather than as 0%.
  final double? fraction;

  /// How many other jobs are running behind [title].
  final int others;

  /// Whole percent, or null for indeterminate.
  ///
  /// What equality is measured in: a restore reports progress per record, and
  /// re-posting the notification for every one of them is thousands of binder
  /// calls a minute for a bar that does not visibly move.
  int? get percent => fraction == null ? null : (fraction! * 100).round();

  @override
  bool operator ==(Object other) =>
      other is BackgroundWorkStatus &&
      other.title == title &&
      other.detail == detail &&
      other.percent == percent &&
      other.others == others;

  @override
  int get hashCode => Object.hash(title, detail, percent, others);

  @override
  String toString() =>
      'BackgroundWorkStatus($title, $detail, $percent%, +$others)';
}

/// The platform end: posts the status and keeps the process alive while it is
/// up.
abstract interface class BackgroundWorkHost {
  /// Shows [status]. The first call after [stop] is the one that asks the OS
  /// to keep the app running.
  Future<void> show(BackgroundWorkStatus status);

  /// Takes the notification down and lets the OS suspend the app again.
  Future<void> stop();
}

/// Long-running jobs the user started, and the notification that keeps them
/// alive.
///
/// Android freezes a backgrounded app within seconds and kills it soon after,
/// so a backup, a restore or a batch of photos still uploading simply stopped
/// when the user switched away to wait for it. A foreground service is the one
/// thing Android lets an app do about that, and its price is a notification —
/// which is also the right place to say how far along the job is.
///
/// Jobs are counted rather than owning the notification each: a backup
/// started while photos are uploading must not take the notification down
/// when it finishes first. The oldest job still running is the headline; the
/// rest are a count beside it.
class BackgroundWork {
  BackgroundWork({BackgroundWorkHost? host}) : _host = host;

  final BackgroundWorkHost? _host;
  final List<BackgroundWorkHandle> _active = [];

  BackgroundWorkStatus? _shown;
  Future<void> _pending = Future.value();

  BackgroundWorkHandle? _uploads;

  /// What the notification says now, or null when nothing is running.
  BackgroundWorkStatus? get current {
    if (_active.isEmpty) return null;
    final head = _active.first;
    return BackgroundWorkStatus(
      title: head._title,
      detail: head._detail,
      fraction: head._fraction,
      others: _active.length - 1,
    );
  }

  /// Starts a job. Every handle must be [BackgroundWorkHandle.end]ed; [run]
  /// does that for you.
  BackgroundWorkHandle begin(String title, {String? detail, double? fraction}) {
    final handle = BackgroundWorkHandle._(this, title, detail, fraction);
    _active.add(handle);
    _publish();
    return handle;
  }

  /// Runs [body] as one job, ending it however [body] finishes.
  Future<T> run<T>(
    String title,
    Future<T> Function(BackgroundWorkHandle job) body,
  ) async {
    final job = begin(title);
    try {
      return await body(job);
    } finally {
      job.end();
    }
  }

  /// Mirrors the attachment upload queue: one job for as long as anything in
  /// it is still unfinished, its bar the average of their progress.
  void reflectUploads(List<UploadTask> tasks) {
    final open = [
      for (final task in tasks)
        if (!task.isTerminal) task,
    ];
    if (open.isEmpty) {
      _uploads?.end();
      _uploads = null;
      return;
    }

    final title = weftPlatformL10n().backgroundWorkSendingAttachments(
      open.length,
    );
    final fraction =
        open.fold<double>(0, (sum, task) => sum + task.progress) / open.length;
    final uploads = _uploads;
    if (uploads == null) {
      _uploads = begin(title, fraction: fraction);
    } else {
      uploads._title = title;
      uploads.update(fraction: fraction);
    }
  }

  /// Settles once every status change so far has reached the host. For tests.
  @visibleForTesting
  Future<void> get idle => _pending;

  void _end(BackgroundWorkHandle handle) {
    if (_active.remove(handle)) _publish();
  }

  void _publish() {
    final host = _host;
    if (host == null) return;
    final next = current;
    if (next == _shown) return;
    _shown = next;
    // Chained, so a stop can never overtake the show it follows — the
    // notification of a job that already finished staying up forever.
    _pending = _pending.then((_) async {
      try {
        if (next == null) {
          await host.stop();
        } else {
          await host.show(next);
        }
      } catch (error) {
        // The job runs either way; without the notification it is merely
        // killable again, as it was before.
        debugPrint('Background work notification failed: $error');
      }
    });
  }
}

/// One running job.
class BackgroundWorkHandle {
  BackgroundWorkHandle._(
    this._owner,
    this._title,
    this._detail,
    this._fraction,
  );

  final BackgroundWork _owner;
  String _title;
  String? _detail;
  double? _fraction;
  bool _ended = false;

  /// Moves the bar, and optionally the second line. A null [fraction] keeps
  /// the bar where it was; pass [indeterminate] to make it spin instead.
  void update({String? detail, double? fraction, bool indeterminate = false}) {
    if (_ended) return;
    if (detail != null) _detail = detail;
    if (indeterminate) {
      _fraction = null;
    } else if (fraction != null) {
      _fraction = fraction.clamp(0.0, 1.0);
    }
    _owner._publish();
  }

  /// Finishes the job. Safe to call twice.
  void end() {
    if (_ended) return;
    _ended = true;
    _owner._end(this);
  }
}

/// The notification id the background-work notification is posted under.
final int kBackgroundWorkNotificationId = stableNotificationId(
  'weft.background-work',
);

/// Android: a `dataSync` foreground service whose notification is the status.
///
/// The service is the plugin's own; it does no work, it exists for the process
/// priority that comes with it. The jobs keep running in the main isolate,
/// where the database and the Matrix client already are.
class AndroidBackgroundWorkHost implements BackgroundWorkHost {
  AndroidBackgroundWorkHost({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  bool _started = false;

  AndroidFlutterLocalNotificationsPlugin? get _android => _plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();

  @override
  Future<void> show(BackgroundWorkStatus status) async {
    final android = _android;
    if (android == null) return;
    final details = _details(status);
    if (_started) {
      // Same id as the service's own notification, so this replaces it in
      // place instead of restarting the service for every percent.
      await _plugin.show(
        id: kBackgroundWorkNotificationId,
        title: status.title,
        body: status.detail,
        notificationDetails: NotificationDetails(android: details),
      );
      return;
    }
    // A foreground service whose channel does not exist yet crashes the app on
    // start. Notifications are normally initialised by now, but a job started
    // before the user ever opened them must not be the thing that finds out.
    await android.createNotificationChannel(
      weftNotificationChannels().firstWhere(
        (channel) => channel.id == kBackgroundChannelId,
      ),
    );
    await android.startForegroundService(
      id: kBackgroundWorkNotificationId,
      title: status.title,
      body: status.detail,
      notificationDetails: details,
      startType: AndroidServiceStartType.startNotSticky,
      foregroundServiceTypes: {
        AndroidServiceForegroundType.foregroundServiceTypeDataSync,
      },
    );
    _started = true;
  }

  @override
  Future<void> stop() async {
    final android = _android;
    if (android == null || !_started) return;
    _started = false;
    await android.stopForegroundService();
    await _plugin.cancel(id: kBackgroundWorkNotificationId);
  }

  AndroidNotificationDetails _details(BackgroundWorkStatus status) {
    final l10n = weftPlatformL10n();
    return AndroidNotificationDetails(
      kBackgroundChannelId,
      l10n.notificationChannelBackground,
      channelDescription: l10n.notificationChannelBackgroundDescription,
      importance: Importance.low,
      priority: Priority.low,
      category: AndroidNotificationCategory.progress,
      ongoing: true,
      autoCancel: false,
      onlyAlertOnce: true,
      silent: true,
      showProgress: true,
      maxProgress: 100,
      progress: status.percent ?? 0,
      indeterminate: status.percent == null,
      subText: status.others > 0
          ? l10n.backgroundWorkMore(status.others)
          : null,
    );
  }
}

/// iOS: borrows the few minutes of background time the OS grants a task in
/// progress.
///
/// iOS has nothing like a foreground service and no way to put a progress bar
/// on a notification, so there is nothing to show. What it does have is
/// `beginBackgroundTask`, which is what lets a backup or an upload started
/// just before the user switched away finish instead of freezing mid-file.
class IosBackgroundWorkHost implements BackgroundWorkHost {
  IosBackgroundWorkHost({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const String channelName = 'com.bostrot.weft/background_work';

  final MethodChannel _channel;
  bool _started = false;

  @override
  Future<void> show(BackgroundWorkStatus status) async {
    if (_started) return;
    _started = true;
    await _channel.invokeMethod<void>('begin', {'name': status.title});
  }

  @override
  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    await _channel.invokeMethod<void>('end');
  }
}

/// The host for this platform, or null where a backgrounded app keeps running
/// anyway — every desktop.
BackgroundWorkHost? backgroundWorkHostForPlatform() {
  if (kIsWeb) return null;
  return switch (defaultTargetPlatform) {
    TargetPlatform.android => AndroidBackgroundWorkHost(),
    TargetPlatform.iOS => IosBackgroundWorkHost(),
    _ => null,
  };
}

/// The app's one [BackgroundWork]. Overridden in tests.
final backgroundWorkProvider = Provider<BackgroundWork>(
  (ref) => BackgroundWork(host: backgroundWorkHostForPlatform()),
);
