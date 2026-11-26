import 'package:test/test.dart';
import 'package:weft_sync/weft_sync.dart';

void main() {
  test('the on-device model stays on the device that downloaded it', () {
    // The laptop that receives this phone's AI settings has no copy of the
    // model and must keep asking its server.
    expect(SyncPolicy.syncsSetting('ai.on_device_model'), isFalse);
    expect(SyncPolicy.syncsSetting('ai.on_device_mobile_data'), isFalse);
    expect(SyncPolicy.syncsSetting('ai.llm_base_url'), isTrue);
    expect(SyncPolicy.syncsSetting('ai.llm_model'), isTrue);
  });
}
