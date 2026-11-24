import '../../data/remote_chat_repository.dart';

/// Only the browser build connects to a phone.
Future<RemoteChatRepository> connectToPhone() =>
    throw UnsupportedError('Only Sennit Web connects to a phone');

/// Only the browser build has a pairing to forget.
void forgetPhone() {}
