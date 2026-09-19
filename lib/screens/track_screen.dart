import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/hand.dart';
import '../services/app_settings.dart';
import '../services/arm_controller.dart';
import '../services/tracker.dart';
import '../widgets/glass.dart';
import '../widgets/hand_painter.dart';
import '../widgets/screen_body.dart';

class TrackScreen extends StatelessWidget {
  const TrackScreen({
    super.key,
    required this.tracker,
    required this.arm,
    required this.settings,
    this.trailing,
  });

  final Tracker tracker;
  final ArmController arm;
  final AppSettings settings;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TrackerStage>(
      valueListenable: tracker.stage,
      builder: (context, stage, _) => ScreenBody(
        kicker: 'Vision',
        title: 'Hand tracking',
        trailing: trailing,
        children: switch (stage) {
          TrackerStage.idle || TrackerStage.starting => const [
              _Waiting(),
            ],
          TrackerStage.needsPermission => [
              _Message(
                icon: Icons.no_photography_outlined,
                text: tracker.message.value,
                action: 'Open settings',
                onPressed: () async {
                  await openAppSettings();
                  await tracker.start();
                },
              ),
            ],
          TrackerStage.failed => [
              _Message(
                icon: Icons.error_outline,
                text: tracker.message.value,
                action: 'Try again',
                onPressed: tracker.start,
              ),
            ],
          TrackerStage.running => [
              _Preview(tracker: tracker, arm: arm, settings: settings),
              const SizedBox(height: 14),
              _Angles(arm: arm),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: GlassButton(
                      label: 'Flip camera',
                      icon: Icons.cameraswitch_outlined,
                      onPressed: tracker.canFlip ? tracker.flip : null,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ListenableBuilder(
                      listenable: settings,
                      builder: (context, _) => GlassButton(
                        label: 'Mirror',
                        icon: settings.mirrorOverlay
                            ? Icons.flip
                            : Icons.flip_outlined,
                        onPressed: () =>
                            settings.mirrorOverlay = !settings.mirrorOverlay,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              ListenableBuilder(
                listenable: arm,
                builder: (context, _) => GlassButton(
                  label: arm.manual
                      ? 'Manual — the sliders drive the arm'
                      : 'Auto — your hand drives the arm',
                  icon: arm.manual ? Icons.pan_tool_outlined : Icons.back_hand,
                  filled: !arm.manual,
                  onPressed: () => arm.manual = !arm.manual,
                ),
              ),
            ],
        },
      ),
    );
  }
}

class _Preview extends StatelessWidget {
  const _Preview({
    required this.tracker,
    required this.arm,
    required this.settings,
  });

  final Tracker tracker;
  final ArmController arm;
  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<CameraController?>(
      valueListenable: tracker.controller,
      builder: (context, cam, _) {
        if (cam == null || !cam.value.isInitialized) return const _Waiting();

        return DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            boxShadow: context.glassShadow,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: AspectRatio(
              // The camera's own ratio, uprighted — anything else letterboxes
              // the preview inside the card in black.
              aspectRatio: 1 / cam.value.aspectRatio,
              child: ColoredBox(
                color: Colors.black,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Center(
                      // `child` is stacked inside the preview's own aspect
                      // ratio box, so the painter's canvas is exactly the
                      // frame the landmarks came from.
                      child: CameraPreview(
                        cam,
                        child: RepaintBoundary(
                          child: CustomPaint(
                            painter: HandPainter(
                              hand: tracker.hand,
                              angles: arm.anglesListenable,
                              mirror: settings.mirrorOverlay,
                              accent: settings.accentColor,
                            ),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      top: 12,
                      left: 12,
                      child: ValueListenableBuilder<Hand?>(
                        valueListenable: tracker.hand,
                        builder: (context, hand, _) => _Chip(
                          dot: hand == null
                              ? const Color(0xFFFF3B30)
                              : const Color(0xFF34D399),
                          text: hand == null ? 'NO HAND' : 'TRACKING',
                        ),
                      ),
                    ),
                    Positioned(
                      top: 12,
                      right: 12,
                      child: ValueListenableBuilder<double>(
                        valueListenable: tracker.fps,
                        builder: (context, fps, _) =>
                            _Chip(text: '${fps.toStringAsFixed(1)} FPS'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The small monospace tags floating on the camera frame.
class _Chip extends StatelessWidget {
  const _Chip({required this.text, this.dot});

  final String text;
  final Color? dot;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot != null) ...[
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
            ),
            const SizedBox(width: 7),
          ],
          Text(
            text,
            style: monoStyle(size: 11, colour: Colors.white)
                .copyWith(letterSpacing: 0.6),
          ),
        ],
      ),
    );
  }
}

/// The four angles, exactly as they were sent.
class _Angles extends StatelessWidget {
  const _Angles({required this.arm});

  final ArmController arm;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;

    return ListenableBuilder(
      listenable: arm,
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) {
          // Two to a row, however many joints the arm has.
          final width = (constraints.maxWidth - 12) / 2;

          return Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (var i = 0; i < arm.config.channels; i++)
                SizedBox(
                  width: width,
                  child: GlassCard(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 15),
                    radius: 20,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          arm.config.joints[i].name.toUpperCase(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.1,
                            color: context.glassMuted,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.baseline,
                          textBaseline: TextBaseline.alphabetic,
                          children: [
                            Text(
                              '${arm.angles[i]}',
                              style: monoStyle(size: 26, colour: accent),
                            ),
                            Text(
                              '  deg',
                              style: TextStyle(
                                fontSize: 12,
                                color: context.glassMuted,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _Waiting extends StatelessWidget {
  const _Waiting();

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(vertical: 120),
        child: Center(child: CircularProgressIndicator()),
      );
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.text,
    required this.action,
    required this.onPressed,
  });

  final IconData icon;
  final String text;
  final String action;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(24, 30, 24, 26),
      child: Column(
        children: [
          Icon(icon, size: 40, color: context.glassMuted),
          const SizedBox(height: 16),
          Text(text, textAlign: TextAlign.center),
          const SizedBox(height: 22),
          GlassButton(
            label: action,
            icon: Icons.refresh,
            filled: true,
            onPressed: onPressed,
          ),
        ],
      ),
    );
  }
}
