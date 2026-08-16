/// The MCP server: Weft's tool surface, its API-key authorisation, and the
/// Cloudflare tunnel that exposes it.
///
/// Authorisation lives with the tools rather than the transport, so scope
/// checks, rate limits and the audit log hold however a call arrives — local
/// port, tunnel, or in-process test.
library;

export 'src/api_keys.dart';
export 'src/cloudflared.dart';
export 'src/data_source.dart';
export 'src/http_server.dart';
export 'src/tool_registry.dart';
