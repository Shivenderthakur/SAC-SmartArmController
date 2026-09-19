import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_arm_controller/models/joint.dart';

/// The board drawing and its pin table are third-party files. These guard the
/// two things about them the app cannot work without.
void main() {
  test('the board drawing carries no filters', () {
    final svg = File('assets/board/board.svg').readAsStringSync();

    // flutter_svg drops every element that references a filter, and on this
    // artwork that is all of them: the board renders as a blank rectangle.
    // Re-copying the upstream file without stripping them would silently undo
    // the Board screen.
    expect(svg.contains('filter="url('), isFalse,
        reason: 'filtered elements will not render at all');
    expect(svg.contains('<filter'), isFalse);
    expect(svg.contains('viewBox="0 0 27.9 56.6"'), isTrue,
        reason: 'the pin coordinates are mapped against this viewBox');
  });

  test('every pin a servo may use has a place on the board', () {
    final json = jsonDecode(File('assets/board/board.json').readAsStringSync())
        as Map<String, Object?>;
    final pins = json['pins'] as Map<String, Object?>;

    final targets = pins.values
        .map((p) => (p as Map<String, Object?>)['target'] as String?)
        .toSet();

    for (final gpio in allowedPins) {
      expect(targets, contains('GPIO$gpio'),
          reason: 'GPIO$gpio has no pin in board.json, so it cannot be drawn');
    }
  });
}
