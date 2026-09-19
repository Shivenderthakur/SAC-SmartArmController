import 'package:flutter/foundation.dart';

import 'arm_link.dart';
import 'joint_config.dart';

/// The servo angles, wherever they came from.
///
/// Hand tracking, the manual sliders and sequence playback all write here, and
/// this is the only thing that talks to [ArmLink] - so whatever is on screen is
/// what the arm was told, with no second path to keep in sync.
class ArmController extends ChangeNotifier {
  ArmController(this.link, this.config) {
    _angles = config.restPose;
    anglesListenable = ValueNotifier<List<int>>(_angles);
    config.addListener(_fitToConfig);
  }

  final ArmLink link;
  final JointConfig config;

  late List<int> _angles;
  bool _manual = false;

  /// The same angles as a [ValueListenable], for the overlay painter's
  /// `repaint:` - it must not rebuild a widget to redraw at frame rate.
  late final ValueNotifier<List<int>> anglesListenable;

  List<int> get angles => _angles;

  /// While manual, hand tracking still runs and draws, but stops driving the
  /// arm. Otherwise the two sources would fight over every frame.
  bool get manual => _manual;
  set manual(bool v) {
    if (_manual == v) return;
    _manual = v;
    notifyListeners();
  }

  /// An arm that the camera cannot drive is always on the sliders.
  void _fitToConfig() {
    final next = List<int>.of(config.restPose);
    for (var i = 0; i < next.length && i < _angles.length; i++) {
      next[i] = _angles[i].clamp(config.joints[i].min, config.joints[i].max);
    }
    if (!config.trackingUsable) _manual = true;
    _apply(next);
    notifyListeners();
  }

  /// Tracking only ever yields base, lift, reach and claw, so it is projected
  /// onto whichever joints asked for those, and the rest hold their position.
  void fromHand(List<int> tracked) {
    if (_manual || !config.trackingUsable) return;

    final next = List<int>.of(_angles);
    for (var i = 0; i < config.channels; i++) {
      final source = config.joints[i].source;
      if (source == null) continue;
      final value = tracked[source.index];
      next[i] = value.clamp(config.joints[i].min, config.joints[i].max);
    }
    _apply(next);
  }

  void setChannel(int index, int value) {
    final next = List<int>.of(_angles);
    final joint = config.joints[index];
    next[index] = value.clamp(joint.min, joint.max);
    _manual = true;
    _apply(next);
  }

  /// A whole pose at once, for playing back a recorded step.
  void setPose(List<int> pose) {
    final next = List<int>.of(_angles);
    for (var i = 0; i < next.length && i < pose.length; i++) {
      next[i] = pose[i].clamp(config.joints[i].min, config.joints[i].max);
    }
    _manual = true;
    _apply(next);
  }

  void centre() {
    _manual = true;
    _apply(config.restPose);
  }

  void _apply(List<int> next) {
    if (listEquals(next, _angles)) return;
    _angles = next;
    anglesListenable.value = next;
    // The desktop script only wrote to the port when a value changed.
    link.send(next);
    notifyListeners();
  }

  @override
  void dispose() {
    config.removeListener(_fitToConfig);
    anglesListenable.dispose();
    super.dispose();
  }
}
