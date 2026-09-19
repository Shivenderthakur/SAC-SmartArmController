import 'dart:convert';

import 'package:flutter/services.dart';

/// One header pin, at its place on the board.
class BoardPin {
  const BoardPin({
    required this.label,
    required this.gpio,
    required this.x,
    required this.y,
  });

  /// What is printed on the silkscreen: "16", "VP", "GND.1".
  final String label;

  /// The GPIO behind it, or -1 for power and ground.
  final int gpio;

  /// Millimetres from the board's top-left corner.
  final double x;
  final double y;

  bool get onLeftHeader => x < BoardLayout.widthMm / 2;
}

/// The board drawing and where its pins sit.
///
/// `board.json` measures in millimetres and `board.svg` carries the same
/// numbers in its `viewBox`, so a pin's coordinate maps straight onto the
/// rendered picture without any calibration.
class BoardLayout {
  const BoardLayout(this.pins);

  /// From the SVG's viewBox. `board.json` says 56.628 for the height; the 0.05%
  /// difference is invisible and using the viewBox keeps the dots on the
  /// drawing rather than on the numbers.
  static const widthMm = 27.9;
  static const heightMm = 56.6;

  static const svgAsset = 'assets/board/board.svg';
  static const _jsonAsset = 'assets/board/board.json';

  final List<BoardPin> pins;

  static Future<BoardLayout> load() async {
    final decoded =
        jsonDecode(await rootBundle.loadString(_jsonAsset)) as Map<String, Object?>;
    final raw = decoded['pins'] as Map<String, Object?>? ?? {};

    final pins = <BoardPin>[];
    raw.forEach((label, value) {
      final pin = value as Map<String, Object?>;
      final target = pin['target'] as String? ?? '';
      pins.add(BoardPin(
        label: label,
        gpio: target.startsWith('GPIO') ? int.parse(target.substring(4)) : -1,
        x: (pin['x'] as num).toDouble(),
        y: (pin['y'] as num).toDouble(),
      ));
    });
    return BoardLayout(pins);
  }

  BoardPin? forGpio(int gpio) =>
      pins.where((p) => p.gpio == gpio).firstOrNull;
}
