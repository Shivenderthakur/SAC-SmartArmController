import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_arm_controller/models/joint.dart';
import 'package:smart_arm_controller/services/joint_config.dart';

Future<JointConfig> freshConfig([Map<String, Object> stored = const {}]) async {
  SharedPreferences.setMockInitialValues(stored);
  return JointConfig.load();
}

void main() {
  test('starts as the arm the app has always driven', () async {
    final config = await freshConfig();

    expect(config.channels, 4);
    expect(config.pinMap, [16, 17, 18, 19]);
    expect(config.mirrorClaw, isTrue);
    expect(config.trackingUsable, isTrue);
  });

  test('refuses a pin that already drives another joint', () async {
    final config = await freshConfig();

    expect(config.assign(1, 16), AssignResult.taken);
    expect(config.pinMap[1], 17, reason: 'the refused pin was taken anyway');

    expect(config.assign(1, 21), AssignResult.ok);
    expect(config.pinMap[1], 21);

    // The rest of the header is strapping pins, flash and the serial log.
    expect(config.assign(0, 99), AssignResult.notAllowed);
  });

  test('a fifth joint takes channel 5 back from the claw mirror', () async {
    final config = await freshConfig();
    expect(config.mirrorClaw, isTrue);

    config.resize(5);

    // Channel 5 is a real servo now; mirroring the claw onto it would overwrite
    // that joint on every command.
    expect(config.mirrorClaw, isFalse);
    // And the camera only ever yields four values, so it cannot drive this arm.
    expect(config.trackingUsable, isFalse);
  });

  test('growing and shrinking keeps the joints that survive', () async {
    final config = await freshConfig();
    config.assign(0, 32);

    config.resize(6);
    expect(config.channels, 6);
    expect(config.pinMap.first, 32, reason: 'an existing assignment was lost');
    expect(
      config.pinMap.sublist(4).every(allowedPins.contains),
      isTrue,
      reason: 'new joints should land on free pins',
    );
    expect(config.pinMap.toSet().length, 6, reason: 'two joints share a pin');

    config.resize(3);
    expect(config.channels, 3);
    expect(config.pinMap.first, 32);
  });

  test('survives a restart', () async {
    SharedPreferences.setMockInitialValues({});
    final first = await JointConfig.load();
    first.resize(6);
    first.rename(5, 'Gripper');
    first.assign(5, 33);

    final second = await JointConfig.load();
    expect(second.channels, 6);
    expect(second.joints[5].name, 'Gripper');
    expect(second.joints[5].gpio, 33);
  });

  test('falls back to the default arm when the stored config is unreadable',
      () async {
    expect((await freshConfig({'joints_v1': 'not json at all'})).channels, 4);
    expect((await freshConfig({'joints_v1': '"a string"'})).channels, 4);
    expect((await freshConfig({'joints_v1': '{"v":1,"joints":[]}'})).channels, 4);
  });
}
