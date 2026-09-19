import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/* ------------------------------------------------------------------ *
 *  config - the constants from the Python, unchanged
 * ------------------------------------------------------------------ */

const xMin = 0, xMid = 75, xMax = 150;
const palmAngleMin = -50, palmAngleMid = 20;

const yMin = 0, yMid = 90, yMax = 180;
const wristYMin = 0.3, wristYMax = 0.9;

const zMin = 10, zMid = 90, zMax = 180;
const palmSizeMin = 0.1, palmSizeMax = 0.3;

const clawOpenAngle = 60, clawCloseAngle = 0;
const fistThreshold = 7.0;

// Tracking always yields four values in this order - base, lift, reach, claw -
// and never more. Which joints they drive is the job of the joint config in
// models/joint.dart, so an arm can have nine servos and still be tracked on the
// three the camera can actually measure.

double clamp(double n, double minn, double maxn) =>
    math.max(math.min(maxn, n), minn);

/// `abs((x - in_min) * (out_max - out_min) // (in_max - in_min) + out_min)`
///
/// Python's `//` floors towards negative infinity, which matters here because
/// every mapping inverts its output and so runs the numerator negative.
double mapRange(
    double x, double inMin, double inMax, double outMin, double outMax) {
  final scaled = (x - inMin) * (outMax - outMin) / (inMax - inMin);
  return (scaled.floorToDouble() + outMin).abs();
}

/// A hand, as 21 normalised x/y/z landmarks in the upright, unmirrored frame.
class Hand {
  Hand(this.raw);

  final Float64List raw;

  double x(int i) => raw[i * 3];
  double y(int i) => raw[i * 3 + 1];
  double z(int i) => raw[i * 3 + 2];

  double distanceFrom(int origin, int i) {
    final dx = x(origin) - x(i);
    final dy = y(origin) - y(i);
    final dz = z(origin) - z(i);
    return math.sqrt(dx * dx + dy * dy + dz * dz);
  }
}

const _wrist = 0;
const _indexFingerMcp = 5;
const _fingerJoints = [7, 8, 11, 12, 15, 16, 19, 20];

bool isFist(Hand hand, double palmSize) {
  var sum = 0.0;
  for (final i in _fingerJoints) {
    sum += hand.distanceFrom(_wrist, i);
  }
  return sum / palmSize < fistThreshold;
}

List<int> landmarkToServoAngle(Hand hand) {
  final servo = <double>[
    xMid.toDouble(),
    yMid.toDouble(),
    zMid.toDouble(),
    clawOpenAngle.toDouble(),
  ];

  final palmSize = hand.distanceFrom(_wrist, _indexFingerMcp);

  servo[3] = isFist(hand, palmSize)
      ? clawCloseAngle.toDouble()
      : clawOpenAngle.toDouble();

  // x - the tilt of the palm, wrist against the index knuckle
  final angle = (hand.x(_wrist) - hand.x(_indexFingerMcp)) / palmSize;
  final degrees = (angle * 180 / math.pi).truncateToDouble();
  final clamped =
      clamp(degrees, palmAngleMin.toDouble(), palmAngleMid.toDouble());
  servo[0] = mapRange(clamped, palmAngleMin.toDouble(), palmAngleMid.toDouble(),
      xMax.toDouble(), xMin.toDouble());

  // y - how high the wrist sits in frame
  final wristY = clamp(hand.y(_wrist), wristYMin, wristYMax);
  servo[1] =
      mapRange(wristY, wristYMin, wristYMax, yMax.toDouble(), yMin.toDouble());

  // z - palm size stands in for distance from the camera
  final size = clamp(palmSize, palmSizeMin, palmSizeMax);
  servo[2] =
      mapRange(size, palmSizeMin, palmSizeMax, zMax.toDouble(), zMin.toDouble());

  return servo.map((v) => v.toInt()).toList();
}

/// The 21 standard hand connections, for drawing the skeleton.
const handConnections = [
  [0, 1], [1, 2], [2, 3], [3, 4], // thumb
  [0, 5], [5, 6], [6, 7], [7, 8], // index
  [5, 9], [9, 10], [10, 11], [11, 12], // middle
  [9, 13], [13, 14], [14, 15], [15, 16], // ring
  [13, 17], [17, 18], [18, 19], [19, 20], [0, 17], // pinky + palm
];
