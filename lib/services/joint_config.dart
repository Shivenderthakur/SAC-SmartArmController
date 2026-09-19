import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/joint.dart';

/// Why a pin could not be taken.
enum AssignResult { ok, taken, notAllowed }

/// The arm's shape: how many joints it has, what they are called and which pin
/// each one drives.
///
/// Deliberately not part of [AppSettings]: every change there re-pushes the
/// link settings, and dragging a joint across pins would tear the socket down
/// on every frame of the drag.
class JointConfig extends ChangeNotifier {
  JointConfig._(this._prefs, this._joints);

  static const _key = 'joints_v1';

  final SharedPreferences _prefs;
  List<Joint> _joints;

  static Future<JointConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    return JointConfig._(prefs, _read(prefs));
  }

  @visibleForTesting
  static JointConfig forTest(SharedPreferences prefs) =>
      JointConfig._(prefs, _read(prefs));

  static List<Joint> _read(SharedPreferences prefs) {
    final raw = prefs.getString(_key);
    if (raw == null) return List<Joint>.of(defaultJoints);
    try {
      final decoded = jsonDecode(raw) as Map<String, Object?>;
      final list = (decoded['joints'] as List<Object?>? ?? [])
          .map((e) => Joint.fromJson(e as Map<String, Object?>))
          .toList();
      return list.isEmpty ? List<Joint>.of(defaultJoints) : list;
    } catch (_) {
      // Anything unreadable - half-written, hand-edited, or from a future
      // version - is not worth failing a launch over.
      return List<Joint>.of(defaultJoints);
    }
  }

  List<Joint> get joints => List<Joint>.unmodifiable(_joints);
  int get channels => _joints.length;

  /// The pin per channel, in channel order — exactly what the board is told.
  List<int> get pinMap => _joints.map((j) => j.gpio).toList();

  List<int> get restPose => _joints.map((j) => j.rest).toList();

  /// Channel 5 carries a mirrored copy of the claw for a gripper built from two
  /// opposed servos. That only holds while the arm is small enough for channel
  /// 5 to be free; on a bigger arm it is a real joint and must not be
  /// overwritten by its own mirror.
  bool get mirrorClaw => _joints.length < 5;

  /// Tracking yields three joints and a claw and nothing more, so a larger arm
  /// cannot be driven by the camera at all.
  bool get trackingUsable => _joints.length <= 4;

  /// Which channel a pin currently belongs to, or null if it is free.
  int? ownerOf(int gpio) {
    for (var i = 0; i < _joints.length; i++) {
      if (_joints[i].gpio == gpio) return i;
    }
    return null;
  }

  AssignResult assign(int channel, int gpio) {
    if (!allowedPins.contains(gpio)) return AssignResult.notAllowed;
    final owner = ownerOf(gpio);
    if (owner != null && owner != channel) return AssignResult.taken;

    _joints[channel] = _joints[channel].copyWith(gpio: gpio);
    _save();
    return AssignResult.ok;
  }

  void unassign(int channel) {
    if (!_joints[channel].assigned) return;
    _joints[channel] = _joints[channel].copyWith(gpio: Joint.unassigned);
    _save();
  }

  void rename(int channel, String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == _joints[channel].name) return;
    _joints[channel] = _joints[channel].copyWith(name: trimmed);
    _save();
  }

  /// Grows or shrinks the arm, keeping the joints that survive exactly as they
  /// were — resizing is not a reason to lose someone's pin assignments.
  void resize(int count) {
    final wanted = count.clamp(1, maxJoints);
    if (wanted == _joints.length) return;

    if (wanted < _joints.length) {
      _joints = _joints.sublist(0, wanted);
    } else {
      for (var i = _joints.length; i < wanted; i++) {
        final joint = spareJoint(i);
        final free = allowedPins.firstWhere(
          (p) => ownerOf(p) == null,
          orElse: () => Joint.unassigned,
        );
        _joints.add(joint.copyWith(gpio: free));
      }
    }
    _save();
  }

  void _save() {
    _prefs.setString(
      _key,
      jsonEncode({'v': 1, 'joints': _joints.map((j) => j.toJson()).toList()}),
    );
    notifyListeners();
  }
}
