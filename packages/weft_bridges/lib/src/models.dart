import 'package:meta/meta.dart';
import 'package:weft_domain/weft_domain.dart';

/// A bridge the user runs, as Weft knows it.
@immutable
class BridgeInfo {
  const BridgeInfo({
    required this.id,
    required this.network,
    required this.provisioningUrl,
    this.displayName,
    this.botUserId,
    this.logins = const [],
    this.reachable = true,
  });

  /// Stable local id, usually the bridge's own name.
  final String id;

  final ChatNetwork network;

  /// Base URL of the provisioning API, e.g.
  /// `https://bridge.example.org/_matrix/provision`.
  final Uri provisioningUrl;

  final String? displayName;

  /// The bridge bot, used by the admin-room fallback and for discovery.
  final String? botUserId;

  /// Remote accounts currently logged in through this bridge.
  final List<BridgeLogin> logins;

  /// Whether the last probe reached it. False renders as "offline" rather than
  /// silently showing zero logins, which would look like being signed out.
  final bool reachable;

  String get label => displayName ?? network.label;

  bool get hasLogin => logins.any((l) => l.isActive);

  BridgeInfo copyWith({
    List<BridgeLogin>? logins,
    bool? reachable,
    String? displayName,
    String? botUserId,
  }) {
    return BridgeInfo(
      id: id,
      network: network,
      provisioningUrl: provisioningUrl,
      displayName: displayName ?? this.displayName,
      botUserId: botUserId ?? this.botUserId,
      logins: logins ?? this.logins,
      reachable: reachable ?? this.reachable,
    );
  }

  @override
  bool operator ==(Object other) => other is BridgeInfo && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// State of one remote account on a bridge.
enum BridgeLoginState {
  connected,
  connecting,

  /// Reachable but not currently receiving — usually a transient disconnect.
  transientDisconnect,

  /// Needs the user to log in again.
  badCredentials,

  unknown;

  static BridgeLoginState fromWire(String? raw) => switch (raw?.toUpperCase()) {
    'CONNECTED' => BridgeLoginState.connected,
    'CONNECTING' => BridgeLoginState.connecting,
    'TRANSIENT_DISCONNECT' => BridgeLoginState.transientDisconnect,
    'BAD_CREDENTIALS' => BridgeLoginState.badCredentials,
    _ => BridgeLoginState.unknown,
  };

  bool get needsAttention =>
      this == BridgeLoginState.badCredentials ||
      this == BridgeLoginState.unknown;
}

/// One remote account bridged into Matrix.
@immutable
class BridgeLogin {
  const BridgeLogin({
    required this.id,
    required this.state,
    this.name,
    this.remoteProfileName,
    this.errorMessage,
  });

  final String id;
  final BridgeLoginState state;

  /// Display name of the remote account — the phone number or handle.
  final String? name;
  final String? remoteProfileName;

  /// Why the bridge is unhappy, when it says.
  final String? errorMessage;

  bool get isActive =>
      state == BridgeLoginState.connected ||
      state == BridgeLoginState.connecting ||
      state == BridgeLoginState.transientDisconnect;

  String get label => remoteProfileName ?? name ?? id;
}

/// One way of logging in — QR, phone number, bot token…
///
/// Bridges advertise several; Google Messages offers QR *and* a Google account
/// flow, for instance, so the UI has to let the user pick rather than assuming.
@immutable
class BridgeLoginFlow {
  const BridgeLoginFlow({
    required this.id,
    required this.name,
    this.description,
  });

  final String id;
  final String name;
  final String? description;
}

/// What a login step is asking for.
enum LoginStepType {
  /// Collect typed values from the user.
  userInput,

  /// Show something (QR code, emoji) and wait for the remote side.
  displayAndWait,

  /// Extract cookies via an embedded browser.
  cookies,

  /// Done.
  complete,

  /// A type this build does not know about.
  unsupported;

  static LoginStepType fromWire(String? raw) => switch (raw) {
    'user_input' => LoginStepType.userInput,
    'display_and_wait' => LoginStepType.displayAndWait,
    'cookies' => LoginStepType.cookies,
    'complete' => LoginStepType.complete,
    _ => LoginStepType.unsupported,
  };
}

/// One field in a [LoginStepType.userInput] step.
@immutable
class LoginInputField {
  const LoginInputField({
    required this.id,
    required this.type,
    required this.name,
    this.description,
    this.pattern,
  });

  final String id;

  /// Bridge-declared semantic type: `phone_number`, `email`, `password`,
  /// `token`, `username`, `2fa_code`…
  final String type;

  final String name;
  final String? description;

  /// Validation regex the bridge supplies, applied before submitting so a
  /// typo is caught locally instead of costing a round trip.
  final String? pattern;

  bool get isSecret =>
      type == 'password' || type == 'token' || type.contains('2fa');

  /// Best keyboard for this field.
  String get keyboardHint => switch (type) {
    'phone_number' => 'phone',
    'email' => 'email',
    '2fa_code' => 'number',
    _ => 'text',
  };

  /// Whether [value] satisfies [pattern]. Accepts anything when the bridge
  /// gave no pattern or gave one that does not compile.
  bool validate(String value) {
    if (pattern == null || pattern!.isEmpty) return value.trim().isNotEmpty;
    try {
      return RegExp(pattern!).hasMatch(value);
    } on FormatException {
      return value.trim().isNotEmpty;
    }
  }
}

/// A step in a login flow.
///
/// Rendered generically: a bridge that adds a new field or a new flow works
/// without a client change, which matters because Weft cannot ship an update
/// every time a bridge does.
@immutable
class LoginStep {
  const LoginStep({
    required this.stepId,
    required this.type,
    this.instructions,
    this.fields = const [],
    this.displayData,
    this.displayImageUrl,
    this.displayType,
    this.loginId,
    this.raw = const {},
  });

  final String stepId;
  final LoginStepType type;

  /// Bridge-authored instructions, shown verbatim.
  final String? instructions;

  /// For [LoginStepType.userInput].
  final List<LoginInputField> fields;

  /// For [LoginStepType.displayAndWait]: the QR payload or emoji string.
  final String? displayData;
  final String? displayImageUrl;

  /// `qr`, `emoji`, or `nothing`.
  final String? displayType;

  /// Set on [LoginStepType.complete].
  final String? loginId;

  /// The undecoded step, so an unsupported type can still be shown for
  /// debugging rather than vanishing.
  final Map<String, Object?> raw;

  bool get isTerminal => type == LoginStepType.complete;

  factory LoginStep.fromJson(Map<String, Object?> json) {
    final type = LoginStepType.fromWire(json['type'] as String?);

    final userInput = json['user_input'];
    final fields = <LoginInputField>[];
    if (userInput is Map && userInput['fields'] is List) {
      for (final field in userInput['fields'] as List) {
        if (field is! Map) continue;
        fields.add(
          LoginInputField(
            id: field['id'] as String? ?? '',
            type: field['type'] as String? ?? 'text',
            name: field['name'] as String? ?? field['id'] as String? ?? 'Value',
            description: field['description'] as String?,
            pattern: field['pattern'] as String?,
          ),
        );
      }
    }

    final display = json['display_and_wait'];
    final complete = json['complete'];

    return LoginStep(
      stepId: json['step_id'] as String? ?? '',
      type: type,
      instructions: json['instructions'] as String?,
      fields: fields,
      displayData: display is Map ? display['data'] as String? : null,
      displayImageUrl: display is Map ? display['image_url'] as String? : null,
      displayType: display is Map ? display['type'] as String? : null,
      // The login id appears at the top level on the start response and
      // inside `complete` on the final step; either may be present.
      loginId:
          (complete is Map ? complete['login_id'] as String? : null) ??
          json['login_id'] as String?,
      raw: json,
    );
  }
}

/// Raised when a bridge call fails in a way worth showing the user.
class BridgeException implements Exception {
  const BridgeException(this.message, {this.statusCode, this.errorCode});

  final String message;
  final int? statusCode;

  /// The bridge's own `errcode`, when it sent one.
  final String? errorCode;

  @override
  String toString() => 'BridgeException: $message';
}
