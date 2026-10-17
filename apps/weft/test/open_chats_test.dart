import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:weft/services/notifications/open_chats.dart';

/// The notification path asks this before announcing a message, so every way
/// it can be wrong is either a buzz for something on screen or — worse — a
/// message that never buzzed.
void main() {
  test('a chat is open between entering and leaving it', () {
    final chats = OpenChats(isForeground: () => true);
    expect(chats.isOpen('a'), isFalse);

    chats.enter('a');
    expect(chats.isOpen('a'), isTrue);
    expect(chats.isOpen('b'), isFalse);

    chats.leave('a');
    expect(chats.isOpen('a'), isFalse);
  });

  test('leaving a thread leaves the conversation under it open', () {
    // A thread is the same chat pushed over itself.
    final chats = OpenChats(isForeground: () => true)
      ..enter('a')
      ..enter('a')
      ..leave('a');
    expect(chats.isOpen('a'), isTrue);

    chats.leave('a');
    expect(chats.isOpen('a'), isFalse);
  });

  test('a chat left open in a backgrounded app is not being read', () {
    var foreground = true;
    final chats = OpenChats(isForeground: () => foreground)..enter('a');
    expect(chats.isOpen('a'), isTrue);

    foreground = false;
    expect(chats.isOpen('a'), isFalse);

    foreground = true;
    expect(chats.isOpen('a'), isTrue);
  });

  test('leaving a chat that was never entered does nothing', () {
    final chats = OpenChats(isForeground: () => true)..leave('a');
    expect(chats.isOpen('a'), isFalse);

    chats.enter('a');
    expect(chats.isOpen('a'), isTrue);
  });

  testWidgets('only a resumed app counts as being looked at', (tester) async {
    final chats = OpenChats()..enter('a');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(chats.isOpen('a'), isTrue);

    // A desktop window behind another one, a phone with the shade pulled down.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    expect(chats.isOpen('a'), isFalse);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(chats.isOpen('a'), isFalse);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });
}
