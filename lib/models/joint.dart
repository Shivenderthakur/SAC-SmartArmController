import 'hand.dart';

/// The four things the camera can measure. Tracking will never produce more, so
/// a joint without a source can only be driven by a slider or a saved step.
enum TrackSource { base, lift, reach, claw }

/// One servo: what it is called, how far it may travel, and which pin it is
/// wired to.
///
/// The app owns all of this. The firmware is told only "channel 3 is GPIO18"
/// and the angle to go to, which is why a joint can be renamed or re-limited
/// without reflashing the board.
class Joint {
  const Joint({
    required this.name,
    required this.min,
    required this.max,
    required this.rest,
    this.gpio = unassigned,
    this.source,
  });

  static const unassigned = -1;

  final String name;
  final int min;
  final int max;
  final int rest;

  /// The GPIO this channel drives, or [unassigned].
  final int gpio;

  /// Which tracked value drives this joint, if any.
  final TrackSource? source;

  bool get assigned => gpio != unassigned;

  Joint copyWith({String? name, int? min, int? max, int? rest, int? gpio, Object? source = _keep}) =>
      Joint(
        name: name ?? this.name,
        min: min ?? this.min,
        max: max ?? this.max,
        rest: rest ?? this.rest,
        gpio: gpio ?? this.gpio,
        source: identical(source, _keep) ? this.source : source as TrackSource?,
      );

  Map<String, Object?> toJson() => {
        'name': name,
        'min': min,
        'max': max,
        'rest': rest,
        'gpio': gpio,
        'source': source?.name,
      };

  static Joint fromJson(Map<String, Object?> json) {
    final raw = json['source'] as String?;
    return Joint(
      name: json['name'] as String? ?? 'Joint',
      min: json['min'] as int? ?? 0,
      max: json['max'] as int? ?? 180,
      rest: json['rest'] as int? ?? 90,
      gpio: json['gpio'] as int? ?? unassigned,
      source: TrackSource.values.where((s) => s.name == raw).firstOrNull,
    );
  }

  static const _keep = Object();
}

/// Every pin that may carry a servo, in header order. The firmware refuses
/// anything else: the rest of the header is strapping pins, flash, or the USB
/// serial the log goes out on.
const allowedPins = [16, 17, 18, 19, 21, 22, 23, 32, 33];

/// The most servos one board can drive here, and so the most joints an arm can
/// have: 8 of arm plus a gripper.
final maxJoints = allowedPins.length;

/// The arm the app has always driven: three tracked joints and a claw, on the
/// first four pins.
const defaultJoints = [
  Joint(name: 'X (base)', min: xMin, max: xMax, rest: xMid, gpio: 16, source: TrackSource.base),
  Joint(name: 'Y (lift)', min: yMin, max: yMax, rest: yMid, gpio: 17, source: TrackSource.lift),
  Joint(name: 'Z (reach)', min: zMin, max: zMax, rest: zMid, gpio: 18, source: TrackSource.reach),
  Joint(
    name: 'Claw',
    min: clawCloseAngle,
    max: clawOpenAngle,
    rest: clawOpenAngle,
    gpio: 19,
    source: TrackSource.claw,
  ),
];

/// A joint added by growing the arm: no tracking source, full travel, parked in
/// the middle.
Joint spareJoint(int index) =>
    Joint(name: 'Joint ${index + 1}', min: 0, max: 180, rest: 90);
