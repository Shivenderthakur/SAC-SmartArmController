import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_arm_controller/models/board.dart';
import 'package:smart_arm_controller/screens/board_screen.dart';
import 'package:smart_arm_controller/services/arm_link.dart';
import 'package:smart_arm_controller/services/joint_config.dart';

/// Pumps the Board screen with a five-joint arm whose first joint has no pin.
Future<JointConfig> pumpBoard(WidgetTester tester) async {
  // Tall enough for the board and both pin rails to be laid out at once.
  tester.view.physicalSize = const Size(1200, 3000);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);

  SharedPreferences.setMockInitialValues({});
  final config = await JointConfig.load();
  config.resize(5);
  config.unassign(0);

  // Reading board.json is real I/O, and a widget test only lets that run inside
  // runAsync — so it is parsed here and handed over already loaded. Left to the
  // screen, the future never completes and the pin blocks never appear.
  final layout = await tester.runAsync(BoardLayout.load);

  final link = ArmLink();
  addTearDown(link.dispose);

  // A Scaffold, because refusing a drop raises a SnackBar and ScaffoldMessenger
  // needs one to present into — in the app the screen sits inside HomeShell's.
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: BoardScreen(config: config, link: link, layout: layout),
    ),
  ));
  await tester.pump();
  return config;
}

Future<void> tapText(WidgetTester tester, String text) async {
  final finder = find.text(text);
  expect(finder, findsWidgets, reason: 'nothing on screen reads "$text"');
  await tester.ensureVisible(finder.first);
  await tester.pump();
  await tester.tap(finder.first);
  await tester.pump();
}

void main() {
  testWidgets('shows a block for every pin that can carry a servo',
      (tester) async {
    await pumpBoard(tester);

    // Seven on the right header, two on the left.
    for (final pin in [16, 17, 18, 19, 21, 22, 23, 32, 33]) {
      expect(find.text('GP$pin'), findsOneWidget, reason: 'GPIO$pin is missing');
    }
    // And nothing for the pins that cannot drive a servo.
    expect(find.text('GP0'), findsNothing);
    expect(find.text('GP5'), findsNothing);
  });

  testWidgets('a loose joint can be tapped onto a free pin', (tester) async {
    final config = await pumpBoard(tester);

    await tapText(tester, config.joints[0].name);
    await tapText(tester, 'GP22');

    expect(config.joints[0].gpio, 22);
  });

  testWidgets('a pin that already drives a joint refuses another',
      (tester) async {
    final config = await pumpBoard(tester);
    final taken = config.joints[1].gpio;

    await tapText(tester, config.joints[0].name);
    await tapText(tester, 'GP$taken');

    expect(config.joints[0].assigned, isFalse,
        reason: 'the joint stole a pin that was already driving another');
    expect(config.joints[1].gpio, taken);
    expect(find.textContaining('already drives'), findsOneWidget,
        reason: 'the refusal was silent');

    // Let the SnackBar finish animating and time out, so no timer outlives the
    // test.
    await tester.pump(const Duration(seconds: 5));
  });
}
