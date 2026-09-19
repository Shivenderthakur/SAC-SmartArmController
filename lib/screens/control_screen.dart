import 'package:flutter/material.dart';

import '../services/arm_controller.dart';
import '../services/arm_link.dart';
import '../widgets/glass.dart';
import '../widgets/screen_body.dart';
import '../widgets/servo_slider.dart';

/// Drive the arm by hand, without the camera.
///
/// Touching a slider switches the arm to manual, because otherwise the next
/// tracked frame would overwrite whatever was just set.
class ControlScreen extends StatelessWidget {
  const ControlScreen({super.key, required this.arm, this.trailing});

  final ArmController arm;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: arm,
      builder: (context, _) => ScreenBody(
        kicker: 'Manual',
        title: 'Custom control',
        trailing: trailing,
        children: [
          GlassCard(
            padding: const EdgeInsets.fromLTRB(18, 14, 14, 14),
            child: Row(
              children: [
                Icon(
                  arm.manual ? Icons.pan_tool : Icons.waving_hand_outlined,
                  size: 22,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        arm.manual ? 'Manual control' : 'Hand tracking',
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        arm.manual
                            ? 'The sliders drive the arm. Tracking still runs '
                                'but is ignored.'
                            : 'The camera drives the arm. Move a slider to '
                                'take over.',
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.35,
                          color: context.glassMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch(value: arm.manual, onChanged: (v) => arm.manual = v),
              ],
            ),
          ),
          const SizedBox(height: 12),
          for (var i = 0; i < arm.config.channels; i++) ...[
            _Channel(arm: arm, index: i),
            const SizedBox(height: 12),
          ],
          const SizedBox(height: 2),
          Row(
            children: [
              Expanded(
                child: GlassButton(
                  label: 'Centre all',
                  icon: Icons.center_focus_strong_outlined,
                  onPressed: arm.centre,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: GlassButton(
                  label: 'Back to hand',
                  icon: Icons.videocam_outlined,
                  filled: true,
                  onPressed: () => arm.manual = false,
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          const GlassLabel('Command sent to the arm'),
          GlassWell(
            child: SelectableText(
              ArmLink.command(arm.angles, mirrorClaw: arm.config.mirrorClaw),
              style: monoStyle(size: 13).copyWith(height: 1.4),
            ),
          ),
          if (arm.config.mirrorClaw) ...[
            const SizedBox(height: 10),
            Text(
              'Channel 5 mirrors the claw, for a gripper built from two opposed '
              'servos. A fifth joint takes that channel back.',
              style: TextStyle(
                fontSize: 12,
                height: 1.4,
                color: context.glassMuted,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Channel extends StatelessWidget {
  const _Channel({required this.arm, required this.index});

  final ArmController arm;
  final int index;

  @override
  Widget build(BuildContext context) {
    final joint = arm.config.joints[index];
    final (min, max) = (joint.min, joint.max);
    final accent = Theme.of(context).colorScheme.primary;

    return GlassCard(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      joint.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$min to $max degrees',
                      style: TextStyle(
                        fontSize: 12,
                        color: context.glassMuted,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                '${arm.angles[index]}',
                style: monoStyle(size: 26, colour: accent),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ServoSlider(
            value: arm.angles[index].toDouble(),
            min: min.toDouble(),
            max: max.toDouble(),
            onChanged: (v) => arm.setChannel(index, v.round()),
          ),
        ],
      ),
    );
  }
}
