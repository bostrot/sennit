import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_matrix/weft_matrix.dart';

import '../../app/session_providers.dart';
import '../auth/verification_screen.dart';
import 'settings_section.dart';

/// Every login on this account, and what can be done about each one.
///
/// The screen exists because an access token is invisible: a session left
/// behind on a lent laptop or an old phone keeps reading messages forever, and
/// nothing in a messenger surfaces that except a list like this. So the list
/// leads with the two facts that let someone recognise a session they did not
/// mean to leave open — where it was last seen from, and when — and puts the
/// unverified ones near the top, because those are the ones with a question
/// attached.
class DevicesScreen extends ConsumerStatefulWidget {
  const DevicesScreen({super.key});

  @override
  ConsumerState<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends ConsumerState<DevicesScreen> {
  List<WeftDevice>? _devices;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final devices = await ref.read(deviceManagerProvider).devices();
      if (!mounted) return;
      setState(() => _devices = devices);
    } catch (error) {
      // Deliberately broad: a missing session throws a StateError rather than
      // an Exception, and "not signed in" must render as a message like any
      // other failure instead of as an empty list.
      if (!mounted) return;
      setState(() => _error = _sentence(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Runs a device action, showing whatever it has to say and reloading after.
  ///
  /// Every action here changes state on the homeserver, so the list is refetched
  /// rather than patched: guessing that a rename succeeded and drawing the new
  /// name is how a screen ends up disagreeing with the server it is a view of.
  Future<void> _run(Future<void> Function() action, {String? success}) async {
    setState(() => _busy = true);
    try {
      await action();
      if (!mounted) return;
      if (success != null) _say(success);
    } on ReauthCancelled {
      // The user backed out of the password prompt. Nothing happened, and
      // saying so would be noise about their own decision.
    } catch (error) {
      if (mounted) _say(_sentence(error));
    } finally {
      // _load owns the busy flag from here; it is the last word on both the
      // list and whether the screen is still working.
      if (mounted) await _load();
    }
  }

  void _say(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  static String _sentence(Object error) => switch (error) {
    DeviceActionException(:final message) => message,
    _ => error.toString(),
  };

  /// The account password, asked for only when the homeserver demands it.
  ///
  /// Passed to [DeviceManager.signOut] as a callback rather than collected up
  /// front: most requests never reach a re-authentication stage, and a screen
  /// that asks for a password before finding out whether it needs one teaches
  /// people to type it whenever they are asked.
  Future<String?> _askPassword() {
    return showDialog<String>(
      context: context,
      builder: (_) => const _TextPrompt(
        title: 'Confirm it is you',
        message:
            'Your homeserver asks for your account password before it will '
            'sign a session out.',
        fieldLabel: 'Password',
        confirmLabel: 'Confirm',
        obscure: true,
      ),
    );
  }

  Future<void> _rename(WeftDevice device) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _TextPrompt(
        title: 'Rename device',
        message:
            'The name is visible to anyone you share an encrypted room with, '
            'so it is worth being recognisable without being personal.',
        fieldLabel: 'Name',
        confirmLabel: 'Save',
        initialValue: device.displayName ?? '',
      ),
    );

    if (name == null || !mounted) return;
    await _run(
      () =>
          ref.read(deviceManagerProvider).rename(device.deviceId, name.trim()),
      success: 'Renamed.',
    );
  }

  Future<void> _signOut(WeftDevice device) async {
    final confirmed = await _confirm(
      title: 'Sign out ${device.label}?',
      message: device.isCurrent
          ? 'This is the device you are using. Signing it out logs you out of '
                'Weft here, and any messages only this device can decrypt stay '
                'unreadable unless you have a key backup.'
          : 'That session loses access immediately. If you did not recognise '
                'it, change your account password afterwards as well — a '
                'sign-out does not stop whoever has your password logging in '
                'again.',
      confirmLabel: 'Sign out',
    );
    if (!confirmed || !mounted) return;

    await _run(
      () => ref.read(deviceManagerProvider).signOut([
        device.deviceId,
      ], reauth: _askPassword),
      success: 'Signed out ${device.label}.',
    );
  }

  Future<void> _signOutOthers(List<WeftDevice> others) async {
    final confirmed = await _confirm(
      title: others.length == 1
          ? 'Sign out 1 other device?'
          : 'Sign out ${others.length} other devices?',
      message:
          'Everything except this device is signed out. Those sessions can no '
          'longer read new messages, and each will have to verify again when '
          'it signs back in.',
      confirmLabel: 'Sign out others',
    );
    if (!confirmed || !mounted) return;

    await _run(
      () => ref.read(deviceManagerProvider).signOut([
        for (final device in others) device.deviceId,
      ], reauth: _askPassword),
      success: 'Signed out ${others.length} other devices.',
    );
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String confirmLabel,
  }) async {
    final answer = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: context.colors.error,
              foregroundColor: context.colors.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return answer ?? false;
  }

  /// Sends the user into the *existing* verification flow for one device.
  ///
  /// The same screen the auth gate shows after login, with a device id — there
  /// is one verification path in Weft and this is a second entrance to it, not
  /// a second copy of it.
  Future<void> _verify(WeftDevice device) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => VerificationScreen(
          deviceId: device.deviceId,
          onContinue: () => Navigator.of(context).pop(),
        ),
      ),
    );
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final devices = _devices;
    final others = [
      for (final device in devices ?? const <WeftDevice>[])
        if (!device.isCurrent) device,
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Devices'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _busy ? null : _load,
          ),
        ],
      ),
      body: _body(context, devices, others),
    );
  }

  Widget _body(
    BuildContext context,
    List<WeftDevice>? devices,
    List<WeftDevice> others,
  ) {
    if (_error case final message?) {
      return _Message(message: message, onRetry: _busy ? null : _load);
    }
    if (devices == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return ListView(
      padding: const EdgeInsets.all(WeftSpace.lg),
      children: [
        const SettingsSectionHeader(
          title: 'Where you are signed in',
          subtitle:
              'Each of these holds a key to your account. Sign out anything '
              'you do not recognise, and verify the ones you keep so your '
              'encrypted chats trust them.',
        ),
        const SizedBox(height: WeftSpace.sm),
        for (final device in devices)
          _DeviceTile(
            device: device,
            enabled: !_busy,
            onRename: () => _rename(device),
            onSignOut: () => _signOut(device),
            onVerify: device.trust == DeviceTrust.unverified
                ? () => _verify(device)
                : null,
          ),
        if (others.isNotEmpty) ...[
          const Divider(height: WeftSpace.xl),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.logout_rounded, size: 18),
              label: const Text('Sign out other devices'),
              style: OutlinedButton.styleFrom(
                foregroundColor: context.colors.error,
              ),
              onPressed: _busy ? null : () => _signOutOthers(others),
            ),
          ),
        ],
      ],
    );
  }
}

/// A dialog that asks for one line of text and pops it, or pops null.
///
/// Stateful, and owning its controller, because the alternative — building the
/// controller at the call site and disposing it when `showDialog` returns —
/// disposes it while the dialog's exit animation is still rebuilding the field
/// it belongs to. That is a "used after being disposed" assertion in the frame
/// after every dialog, which is exactly what this replaced.
class _TextPrompt extends StatefulWidget {
  const _TextPrompt({
    required this.title,
    required this.message,
    required this.fieldLabel,
    required this.confirmLabel,
    this.initialValue = '',
    this.obscure = false,
  });

  final String title;
  final String message;
  final String fieldLabel;
  final String confirmLabel;
  final String initialValue;
  final bool obscure;

  @override
  State<_TextPrompt> createState() => _TextPromptState();
}

class _TextPromptState extends State<_TextPrompt> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialValue,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.message),
          const SizedBox(height: WeftSpace.md),
          TextField(
            controller: _controller,
            autofocus: true,
            obscureText: widget.obscure,
            decoration: InputDecoration(labelText: widget.fieldLabel),
            onSubmitted: (value) => Navigator.of(context).pop(value),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

/// One session: what it is called, what it is trusted with, and where it was.
class _DeviceTile extends StatelessWidget {
  const _DeviceTile({
    required this.device,
    required this.enabled,
    required this.onRename,
    required this.onSignOut,
    this.onVerify,
  });

  final WeftDevice device;
  final bool enabled;
  final VoidCallback onRename;
  final VoidCallback onSignOut;
  final VoidCallback? onVerify;

  @override
  Widget build(BuildContext context) {
    final detail = [
      device.deviceId,
      describeLastSeen(device.lastSeenAt, now: clock.now()),
      ?device.lastSeenIp,
    ].join(' · ');

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(_icon(device.trust), color: _color(context, device.trust)),
      title: Row(
        children: [
          Flexible(
            child: Text(
              device.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.text.bodyLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (device.isCurrent) ...[
            const SizedBox(width: WeftSpace.sm),
            _Chip(label: 'This device', color: context.palette.online),
          ],
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            trustLabel(device.trust),
            style: context.text.labelMedium?.copyWith(
              color: _color(context, device.trust),
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(
            detail,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: context.text.bodySmall?.copyWith(
              color: context.colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
      isThreeLine: true,
      trailing: PopupMenuButton<String>(
        tooltip: 'Device actions',
        enabled: enabled,
        onSelected: (choice) {
          switch (choice) {
            case 'rename':
              onRename();
            case 'verify':
              onVerify?.call();
            default:
              onSignOut();
          }
        },
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'rename', child: Text('Rename')),
          if (onVerify != null)
            const PopupMenuItem(value: 'verify', child: Text('Verify')),
          const PopupMenuItem(value: 'signout', child: Text('Sign out')),
        ],
      ),
    );
  }

  static IconData _icon(DeviceTrust trust) => switch (trust) {
    DeviceTrust.verified => Icons.verified_user_rounded,
    DeviceTrust.unverified => Icons.gpp_maybe_rounded,
    DeviceTrust.blocked => Icons.gpp_bad_rounded,
    DeviceTrust.noKeys => Icons.no_encryption_gmailerrorred_rounded,
  };

  static Color _color(BuildContext context, DeviceTrust trust) =>
      switch (trust) {
        DeviceTrust.verified => context.palette.online,
        DeviceTrust.unverified || DeviceTrust.blocked => context.colors.error,
        DeviceTrust.noKeys => context.colors.onSurfaceVariant,
      };
}

/// The badge sentence for a trust state.
///
/// Public so the verification banner and the devices list cannot drift into
/// calling the same state two different things.
String trustLabel(DeviceTrust trust) => switch (trust) {
  DeviceTrust.verified => 'Verified',
  DeviceTrust.unverified => 'Not verified',
  DeviceTrust.blocked => 'Blocked',
  DeviceTrust.noKeys => 'No encryption keys',
};

/// When the homeserver last saw a device, in the words a person would use.
///
/// Coarse on purpose past the first day: the server's own timestamp is allowed
/// to be minutes stale, so a to-the-minute rendering of it would be precision
/// the number does not have.
String describeLastSeen(DateTime? at, {required DateTime now}) {
  if (at == null) return 'Last seen unknown';

  final delta = now.difference(at);
  if (delta.isNegative || delta.inMinutes < 5) return 'Active now';
  if (delta.inMinutes < 60) return '${delta.inMinutes} minutes ago';
  if (delta.inHours < 24) {
    return delta.inHours == 1 ? '1 hour ago' : '${delta.inHours} hours ago';
  }
  if (delta.inDays < 7) {
    return delta.inDays == 1 ? 'Yesterday' : '${delta.inDays} days ago';
  }
  return DateFormat.yMMMd().format(at);
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: WeftSpace.sm,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: WeftRadius.allSm,
      ),
      child: Text(
        label,
        style: context.text.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(WeftSpace.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: WeftSpace.lg),
            OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}
