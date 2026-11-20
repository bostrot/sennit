import 'models.dart';

/// Whatever Sennit talks to when it signs someone in to a bridge.
///
/// Two things answer to this. [BridgeProvisioningClient] speaks the bridge's
/// own HTTP API, which describes every step as data. [BridgeCommandClient]
/// speaks to the bridge bot in its chat, typing the commands a person would
/// and reading the replies back into the same steps. The login screen renders
/// steps and nothing else, so which of the two is behind it never shows —
/// which is the point: a person signing in to WhatsApp should not have to know
/// that their server keeps the better of the two doors shut.
abstract interface class BridgeLoginBackend {
  /// Who is signed in, and whether the bridge answers at all.
  Future<BridgeWhoami> whoami();

  /// The ways this bridge offers to sign in.
  Future<List<BridgeLoginFlow>> loginFlows();

  /// Begins [flowId], returning its first step.
  ///
  /// [reloginId] names an existing account to sign in again, which keeps its
  /// chats instead of creating a second account beside the broken one.
  Future<LoginStep> startLogin(String flowId, {String? reloginId});

  /// Submits a step and returns the next one.
  Future<LoginStep> submitStep({
    required String loginId,
    required String stepId,
    required String stepType,
    Map<String, Object?>? body,
  });

  /// Waits on a `display_and_wait` step until the remote side responds, or
  /// the bridge has something new to show — a refreshed QR code arrives as the
  /// same step with new data.
  Future<LoginStep> waitForStep({
    required String loginId,
    required String stepId,
  });

  /// Abandons a login in progress. Best effort: a bridge too old to know the
  /// call forgets the attempt on its own timeout.
  Future<void> cancelLogin(String loginId);

  /// Signs a remote account out of the bridge.
  Future<void> logout(String loginId);

  /// Whether a `cookies` step can be submitted through this backend.
  bool get supportsCookies;

  /// Whether a flow the bridge does not list can still be started.
  ///
  /// The provisioning API starts any flow the connector knows; the bot's
  /// `login` command checks the name against the list first. Google Messages
  /// is where it shows: QR pairing is unlisted but works over the API, and is
  /// refused in the chat.
  bool get acceptsUnlistedFlows;

  void dispose();
}

/// Result of asking a bridge who is signed in.
class BridgeWhoami {
  const BridgeWhoami({
    this.networkId,
    this.networkName,
    this.botUserId,
    this.logins = const [],
    this.flows = const [],
  });

  final String? networkId;
  final String? networkName;

  /// The bridge bot, which `/whoami` names on bridgev2.
  final String? botUserId;

  final List<BridgeLogin> logins;

  /// The login flows, when the answer carried them — bridgev2's `/whoami`
  /// does, which saves a round trip before the first screen.
  final List<BridgeLoginFlow> flows;

  bool get hasActiveLogin => logins.any((login) => login.isActive);
}
