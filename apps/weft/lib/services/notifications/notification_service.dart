import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_matrix/weft_matrix.dart';
import 'package:weft_notify/weft_notify.dart';

import 'notification_channels.dart';
import 'notification_presentation.dart';
import 'push_registration.dart';

/// How many of one chat's messages keep a notification of their own.
///
/// Past this the summary counts them instead — which is exactly what
/// [NotificationSummary.hiddenCount] is for. Android collapses a group anyway,
/// but forty posts is forty parcels through the system's notification service
/// and forty rows for whoever expands the group. Matched to
/// [kMaxSummaryLines] so the rows in the shade and the lines in the summary are
/// the same messages.
const int kMaxNotificationsPerChat = kMaxSummaryLines;

/// How many of one chat's messages are *remembered*, posted or not.
///
/// Larger than [kMaxNotificationsPerChat] because the count is not the same
/// question as the row: a chat left unread over a weekend should say "37 new
/// messages" while showing five of them. Bounded all the same — this is memory
/// held for as long as a notification is up, and past a certain point the exact
/// number stops being information.
const int kMaxTrackedNotificationsPerChat = 99;

/// The conversation a test notification belongs to.
///
/// A real id would be better in exactly one respect — the tap would land in a
/// real chat — and worse in every other. Attributing Weft's own sample text to
/// a friend puts words in their mouth in the shade, counts a message they never
/// sent into their summary, and makes the verdict depend on *their* mute rather
/// than on the settings the user is looking at. So the test gets a conversation
/// of its own; tapping it opens the chat view's unavailable state, which is the
/// one rough edge and is documented rather than hidden.
const String kTestNotificationChatId = 'weft:notification-test';

/// The room behind [kTestNotificationChatId].
///
/// Deliberately not a resolvable room id: `MatrixNotificationSession.lastReadAt`
/// returns null for a room the client has never synced, which is what keeps a
/// test notification from being suppressed as already read.
const String kTestNotificationRoomId = '!notification-test:weft.invalid';

/// What the user did to a notification.
///
/// One type for a tap and for an action because they arrive through the same
/// callback and differ only in whether [actionId] is set. Split into two and the
/// cold-start path has to be written twice.
@immutable
class NotificationActivation {
  const NotificationActivation({
    required this.payload,
    this.actionId,
    this.input,
  });

  final NotificationPayload payload;

  /// One of [WeftNotificationActions], or null when the notification body
  /// itself was tapped.
  final String? actionId;

  /// Text typed into an inline reply. Null for every other action.
  final String? input;

  bool get isTap => actionId == null;

  @override
  String toString() =>
      'NotificationActivation(${actionId ?? 'tap'} on ${payload.eventId})';
}

/// Where a rendered notification is actually posted.
///
/// The one seam between Weft's notification logic and a plugin that needs a
/// device. Everything interesting — which channel, which group, what the body
/// says, whether there should be a summary — is decided above this and arrives
/// as a [NotificationPresentation]; this interface has four methods and no
/// decisions, so a fake of it is four lines and the test that uses it is
/// testing Weft rather than testing `flutter_local_notifications`.
abstract interface class NotificationSink {
  /// Registers channels and categories and starts listening for taps.
  Future<void> initialize(void Function(NotificationActivation) onActivation);

  /// Asks the OS for permission to post at all. True when it is granted, and on
  /// the platforms that do not ask.
  Future<bool> requestPermission();

  Future<void> show(NotificationPresentation presentation);

  /// Publishes the launcher shortcut this conversation's notifications hang
  /// off, so they can become bubbles.
  ///
  /// Android only, and a no-op elsewhere. It is on this interface rather than
  /// called directly because it has to happen *before* the notification that
  /// names the shortcut is posted — Android silently drops the `shortcutId` of
  /// a shortcut that does not exist yet, and a conversation that never bubbles
  /// is a hard failure to notice from a test that cannot see a launcher.
  Future<void> publishConversationShortcut({
    required String id,
    required String chatId,
    required String label,
    required String link,
    String? iconPath,
  });

  /// Removes one posted notification. [tag] is Android's, and must match the
  /// one it was posted with or the cancel silently does nothing.
  Future<void> cancel({required int id, String? tag});

  /// The notification that launched the app, if it was launched by one.
  ///
  /// This is the cold-start half of tap routing: a notification tapped while
  /// Weft was not running fires before any Dart is listening, so the platform
  /// holds it until asked — the same shape as `WeftIntents.deliverInitialIntent`
  /// and for the same reason.
  Future<NotificationActivation?> launchActivation();
}

/// [NotificationSink] over `flutter_local_notifications`.
class LocalNotificationSink implements NotificationSink {
  LocalNotificationSink({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;

  static const MethodChannel _platform = MethodChannel(
    'com.bostrot.weft/intents',
  );

  @override
  Future<void> initialize(
    void Function(NotificationActivation) onActivation,
  ) async {
    await _plugin.initialize(
      settings: InitializationSettings(
        android: const AndroidInitializationSettings('@mipmap/ic_launcher'),
        // Permission is asked for separately, behind the rationale sheet: the
        // OS gives an app one prompt and spending it during initialisation
        // means spending it before the user has seen a single message.
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
          notificationCategories: weftDarwinCategories(),
        ),
        macOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
          notificationCategories: weftDarwinCategories(),
        ),
        linux: const LinuxInitializationSettings(defaultActionName: 'Open'),
        windows: const WindowsInitializationSettings(
          appName: 'Weft',
          appUserModelId: 'com.bostrot.weft',
          // Identifies the COM activation callback. Fixed, because Windows
          // matches a toast's activation against the GUID that posted it: a
          // regenerated one would orphan every notification already in the
          // action centre.
          guid: 'b7f2b2e6-3a4a-4c1e-9f0e-6c9f2b1d5a10',
        ),
      ),
      onDidReceiveNotificationResponse: (response) {
        final activation = _activationFor(response);
        if (activation != null) onActivation(activation);
      },
    );

    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android != null) {
      await android.createNotificationChannelGroup(weftMessagesChannelGroup);
      for (final channel in weftNotificationChannels()) {
        await android.createNotificationChannel(channel);
      }
    }
  }

  @override
  Future<bool> requestPermission() async {
    if (!NotificationPlatform.needsPermissionPrompt) return true;

    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android != null) {
      return await android.requestNotificationsPermission() ?? false;
    }

    final ios = _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >();
    if (ios != null) {
      return await ios.requestPermissions(
            alert: true,
            badge: true,
            sound: true,
          ) ??
          false;
    }

    final macos = _plugin
        .resolvePlatformSpecificImplementation<
          MacOSFlutterLocalNotificationsPlugin
        >();
    return await macos?.requestPermissions(
          alert: true,
          badge: true,
          sound: true,
        ) ??
        false;
  }

  @override
  Future<void> show(NotificationPresentation presentation) => _plugin.show(
    id: presentation.id,
    title: presentation.title,
    body: presentation.body,
    notificationDetails: presentation.details,
    payload: presentation.payload.encode(),
  );

  @override
  Future<void> publishConversationShortcut({
    required String id,
    required String chatId,
    required String label,
    required String link,
    String? iconPath,
  }) async {
    if (!NotificationPlatform.isAndroid) return;
    try {
      // The channel `WeftIntents` already owns. A second channel would be a
      // second front door onto the same activity, and this one is only ever
      // invoked on — the handler stays where it is.
      await _platform.invokeMethod<bool>('publishChatShortcut', {
        'id': id,
        // Sent alongside the id because [id] is sanitised and the platform
        // cannot invert it. A Direct Share tap hands back only the id, and a
        // conversation that got its shortcut from a notification rather than
        // from the ranker would otherwise land on the target picker instead of
        // the chat the user just chose by name.
        'chatId': chatId,
        'label': label,
        'link': link,
        'iconPath': iconPath,
      });
    } on MissingPluginException {
      // A platform with no such handler. Notifications still post.
    } on PlatformException {
      // A launcher that refused. Same consequence.
    }
  }

  @override
  Future<void> cancel({required int id, String? tag}) async {
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android != null) {
      await android.cancel(id: id, tag: tag);
      return;
    }
    await _plugin.cancel(id: id);
  }

  @override
  Future<NotificationActivation?> launchActivation() async {
    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details == null || !details.didNotificationLaunchApp) return null;
    return _activationFor(details.notificationResponse);
  }

  static NotificationActivation? _activationFor(
    NotificationResponse? response,
  ) {
    if (response == null) return null;
    final payload = NotificationPayload.decode(response.payload);
    if (payload == null) return null;
    return NotificationActivation(
      payload: payload,
      actionId: response.actionId,
      input: response.input,
    );
  }
}

/// Resolves an avatar URL to a file the platform can draw.
///
/// A file path, because that is what every backend takes — Android wants a
/// bitmap, Linux an icon path, Windows a `file://` URI. Null when there is
/// nothing to draw, which is the ordinary case for a group room and for a
/// bridge ghost whose profile has not backfilled.
typedef NotificationAvatarLoader = Future<String?> Function(String url);

/// Downloads notification avatars into the cache directory.
///
/// The URL arriving here has already been through `mxcToThumbnailUrl` — the
/// repository stores the resolved HTTP thumbnail on [Chat.avatarUrl], and
/// `mxcToThumbnailUrl` passes an HTTP URL through untouched — so this handles
/// both shapes with one call and keeps the endpoint-generation decision
/// (`/_matrix/client/v1/media` versus `/_matrix/media/v3`) in the one place
/// that already makes it.
///
/// Cached by URL: a chat that posts twenty notifications in a backfill fetches
/// one avatar, and the same face survives the next launch.
class MatrixNotificationAvatars {
  MatrixNotificationAvatars({
    required Directory cacheDirectory,
    required Map<String, String>? headers,
    http.Client? client,
  }) : _cacheDirectory = cacheDirectory,
       _headers = headers,
       _client = client ?? http.Client();

  final Directory _cacheDirectory;
  final Map<String, String>? _headers;
  final http.Client _client;
  final Map<String, String?> _resolved = {};

  Future<String?> load(String url) async {
    if (url.isEmpty) return null;
    if (_resolved.containsKey(url)) return _resolved[url];

    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || uri.scheme.startsWith('mxc')) {
      // An unresolved mxc URI cannot be fetched, and arriving here with one
      // means a caller skipped `mxcToThumbnailUrl`. Failing quietly is right —
      // a notification with initials instead of a face is still a notification.
      return _resolved[url] = null;
    }

    final file = File(
      '${_cacheDirectory.path}/avatar_${stableNotificationId(url)}.img',
    );
    try {
      if (!file.existsSync()) {
        final response = await _client.get(uri, headers: _headers);
        if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
          return _resolved[url] = null;
        }
        await file.create(recursive: true);
        await file.writeAsBytes(response.bodyBytes);
      }
      return _resolved[url] = file.path;
    } on Object catch (error) {
      // A dead socket, a full disk, a 401 from an authenticated media endpoint
      // after a token refresh. None of them is a reason not to notify.
      debugPrint('weft: notification avatar $url could not be loaded: $error');
      return _resolved[url] = null;
    }
  }

  void dispose() => _client.close();
}

/// Turns notification decisions into notifications on the screen.
///
/// The top of the notification stack and the thinnest part of it. Everything
/// that could be decided without a device already was: `weft_notify` said
/// whether to notify and what it should say, `MatrixNotificationPipeline` fed it
/// events from sync and from push, and [NotificationPresentation] rendered the
/// result down to what each platform's plugin takes. What is left here is the
/// bookkeeping that only makes sense next to a real shade — which notifications
/// are currently posted, when a summary should replace them, and where a tap
/// goes.
///
/// It posts nothing on its own initiative. Nothing here decides; if a message
/// reaches [_post] it is because [evaluateNotification] already said it should.
class WeftNotificationService {
  WeftNotificationService({
    required NotificationSink sink,
    required MatrixNotificationPipeline pipeline,
    ChatForRoom? chatForRoom,
    NotificationAvatarLoader? avatarLoader,
    PushTransport? push,
  }) : _sink = sink,
       _pipeline = pipeline,
       _chatForRoom = chatForRoom,
       _avatarLoader = avatarLoader,
       _push = push;

  final NotificationSink _sink;
  final MatrixNotificationPipeline _pipeline;
  final ChatForRoom? _chatForRoom;
  final NotificationAvatarLoader? _avatarLoader;
  final PushTransport? _push;

  /// What is currently on screen, per conversation, oldest first.
  ///
  /// Held rather than read back from the platform because
  /// `getActiveNotifications` is Android-only and lossy — it returns the
  /// rendered strings, not the [NotificationContent] a `MessagingStyle` needs
  /// to redraw the thread.
  final Map<String, List<NotificationContent>> _posted = {};

  /// Avatar file paths by event id, for as long as their notification is up.
  final Map<String, String> _avatars = {};

  /// Serialises [_post]; see [_enqueue].
  Future<void> _queue = Future<void>.value();

  StreamSubscription<MatrixNotification>? _notificationSub;
  StreamSubscription<Map<String, Object?>>? _pushSub;

  /// Where a tapped notification goes.
  ///
  /// A URL rather than a parsed link, and that is the point: the app hands this
  /// to `WeftLink.parse` — the same function `WeftIntents` feeds — so a
  /// notification tap and an `android.intent.action.VIEW` are the same event by
  /// the time either reaches the navigator. A second router is the failure this
  /// avoids.
  void Function(String link)? onOpenLink;

  /// Where a notification *action* goes. Left unset by this task: reply,
  /// mark-as-read and mute-for-an-hour belong to the notification-actions task,
  /// and the seam is here so that task adds a handler rather than a second
  /// delivery path.
  void Function(NotificationActivation activation)? onAction;

  /// Asks for AI answer suggestions for a message about to be posted, given
  /// the whole visible thread (oldest first, the new message last). Unset, or
  /// returning an empty list, means the notification goes out without them.
  /// Failures are the callee's to swallow — a notification never waits on an
  /// error message.
  Future<List<String>> Function(
    NotificationContent content,
    List<NotificationContent> thread,
  )?
  suggestReplies;

  /// Notifications currently posted for [groupKey], oldest first.
  @visibleForTesting
  List<NotificationContent> postedFor(String groupKey) =>
      List.unmodifiable(_posted[groupKey] ?? const []);

  /// Asks the OS for permission to post notifications.
  ///
  /// Separate from [start] because the OS gives an app exactly *one* prompt —
  /// a second call returns the first answer without showing anything — so it
  /// must be spent deliberately, after the rationale sheet and not during
  /// startup. True on the platforms that never ask.
  Future<bool> requestPermission() => _sink.requestPermission();

  /// Wires everything up and replays a cold-start tap.
  ///
  /// Order matters in one place: the pipeline is started *after* the sink is
  /// initialised, so a message arriving in the first frame has somewhere to be
  /// posted to rather than being decided and dropped.
  Future<void> start() async {
    await _sink.initialize(_onActivation);

    _notificationSub ??= _pipeline.notifications.listen(_enqueue);
    _pipeline.start();

    final push = _push;
    if (push != null) {
      // A poke that arrives while the app is running. The pipeline dedupes it
      // against the sync path, so a message that arrives both ways is decided
      // once — which is the normal case, not the exception.
      _pushSub ??= push.pushes.listen((data) => unawaited(handlePush(data)));
    }

    final launch = await _sink.launchActivation();
    if (launch != null) _onActivation(launch);
  }

  /// Decides and posts for one push payload.
  ///
  /// Public because the FCM handler is not the only caller — a "send test
  /// notification" button runs a synthetic payload through exactly this path,
  /// which is the point of having one.
  Future<void> handlePush(Map<String, Object?> data) async {
    final payload = MatrixPushPayload.fromJson(data);
    // A clearing push means the unread count dropped — the user read the room
    // somewhere else. It is a dismissal, and treating it as a malformed message
    // is how a notification outlives the message it was for.
    if (payload != null && payload.isClearing) {
      final roomId = payload.roomId;
      if (roomId != null) await dismissRoom(roomId);
      return;
    }
    await _pipeline.handlePush(data);
  }

  /// Posts a synthetic message through the real decision path.
  ///
  /// The settings screen's "send test notification": it proves the whole chain
  /// — policy, rendering, channel, the platform's own permission state — in one
  /// press, rather than making the user wait for someone to message them. There
  /// is no shortcut in it. The message goes through [evaluateNotification] with
  /// the live policy and through [NotificationContent.forMessage], and reaches
  /// the shade through the same queue every real notification does, so a test
  /// that appears means real ones will too.
  ///
  /// [network] decides which channel it posts on, so the sound and importance
  /// under test are the ones the user's own messages use. The returned decision
  /// is the point of the button as much as the notification is: a suppression
  /// names the setting responsible, which is a far better answer than a button
  /// that appears to do nothing.
  Future<NotificationDecision> sendTestNotification({
    ChatNetwork network = ChatNetwork.matrix,
    DateTime? now,
  }) {
    final stamp = now ?? DateTime.now();
    return _pipeline.handleSynthetic(
      message: WeftMessage(
        // Unique per press: two tests should stack into a thread the way two
        // real messages do, rather than the second silently replacing the
        // first and looking like nothing happened.
        eventId: '\$weft-test-${stamp.microsecondsSinceEpoch}',
        roomId: kTestNotificationRoomId,
        network: network,
        senderId: '@weft-test:weft.invalid',
        senderName: 'Weft',
        timestamp: stamp,
        kind: MessageKind.text,
        isOwn: false,
        body: 'This is what a notification from Weft looks like.',
      ),
      chat: Chat(
        id: kTestNotificationChatId,
        title: 'Notification test',
        sources: [
          ChatSource(roomId: kTestNotificationRoomId, network: network),
        ],
      ),
    );
  }

  /// Clears every notification posted for [groupKey].
  ///
  /// The chat's, not the room's: reading a merged conversation clears both
  /// legs, because the user read the conversation.
  Future<void> dismissChat(String groupKey) async {
    final contents = _posted.remove(groupKey);
    if (contents == null) return;
    for (final content in contents) {
      _avatars.remove(content.eventId);
      // The conversation's one row — and, for notifications posted by builds
      // that keyed per event, each of those too. Cancelling an id that was
      // never posted is a no-op, so the sweep is cheap and the transition
      // leaves nothing behind.
      await _sink.cancel(
        id: stableNotificationId(content.eventId),
        tag: groupKey,
      );
    }
    await _sink.cancel(id: stableNotificationId(groupKey), tag: groupKey);
    await _sink.cancel(
      id: stableNotificationId('summary:$groupKey'),
      tag: 'summary:$groupKey',
    );
  }

  /// Clears the notifications belonging to one *source* room.
  ///
  /// Only a room id is known at the point a clearing push arrives, and a room
  /// is a leg of a chat. Resolving it through [ChatForRoom] — rather than
  /// keying anything on the room — is what keeps the merged contact one thread.
  Future<void> dismissRoom(String roomId) async {
    final chat = _chatForRoom?.call(roomId);
    if (chat != null) {
      await dismissChat(chat.id);
      return;
    }
    // No chat: fall back to the group keys that hold a notification from this
    // room. Correct for a single-source chat, where the two ids are the same.
    for (final entry in _posted.entries.toList()) {
      if (entry.value.any((c) => c.roomId == roomId)) {
        await dismissChat(entry.key);
      }
    }
  }

  Future<void> dispose() async {
    await _notificationSub?.cancel();
    await _pushSub?.cancel();
    _notificationSub = null;
    _pushSub = null;
  }

  /// Posts one after another rather than all at once.
  ///
  /// [_post] awaits an avatar download and several plugin calls, and two
  /// messages decided in the same tick would otherwise interleave across those
  /// awaits — appending to one chat's thread out of order, and racing to post
  /// two summaries that each believe they are the latest. A chain is the whole
  /// fix, and it costs nothing: notifications are rare and already asynchronous.
  void _enqueue(MatrixNotification notification) {
    _queue = _queue.then((_) => _post(notification)).catchError((Object error) {
      // A failure to post one notification must not stop the next one: the
      // chain would be permanently broken by a single dead socket.
      debugPrint('weft: could not post a notification: $error');
    });
  }

  Future<void> _post(MatrixNotification notification) async {
    final content = notification.content;
    final group = content.groupKey;

    final avatarUrl = content.senderAvatarUrl;
    if (avatarUrl != null && avatarUrl.isNotEmpty) {
      final path = await _avatarLoader?.call(avatarUrl);
      if (path != null) _avatars[content.eventId] = path;
    }

    final thread = _posted.putIfAbsent(group, () => [])..add(content);

    if (thread.length > kMaxTrackedNotificationsPerChat) {
      thread.removeRange(0, thread.length - kMaxTrackedNotificationsPerChat);
    }
    // One notification per conversation, re-posted under the same id with
    // the thread's newest lines — the platform replaces it in place, which
    // is what keeps one chat one row however many messages arrive.
    final windowStart = thread.length - kMaxNotificationsPerChat;
    final visible = thread.sublist(windowStart < 0 ? 0 : windowStart);

    // Before the notification that names it: Android drops a `shortcutId`
    // pointing at a shortcut that does not exist, and the conversation loses
    // its bubble with nothing said about it.
    await _sink.publishConversationShortcut(
      id: chatShortcutId(group),
      chatId: group,
      label: content.title,
      link: content.deepLink,
      iconPath: _avatars[content.eventId],
    );

    var aiReplies = const <String>[];
    final suggest = suggestReplies;
    if (suggest != null && !notification.isSilent) {
      try {
        aiReplies = await suggest(
          content,
          visible,
        ).timeout(const Duration(seconds: 10));
      } on Object catch (error) {
        debugPrint('weft: reply suggestions failed: $error');
      }
    }

    await _sink.show(
      NotificationPresentation.forMessage(
        content: content,
        silent: notification.isSilent,
        isGroup: _chatForRoom?.call(content.roomId)?.isGroup ?? false,
        conversation: visible,
        aiReplies: aiReplies,
        avatarPaths: {
          for (final entry in _avatars.entries)
            if (visible.any((c) => c.eventId == entry.key))
              entry.key: entry.value,
        },
      ),
    );

    // No per-chat summary any more: the conversation *is* one notification
    // now, and a summary row beside it would say the same thing twice.
  }

  void _onActivation(NotificationActivation activation) {
    if (!activation.isTap) {
      onAction?.call(activation);
      return;
    }
    onOpenLink?.call(activation.payload.link);
  }
}
