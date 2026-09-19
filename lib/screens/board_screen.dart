import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../models/board.dart';
import '../models/joint.dart';
import '../services/arm_link.dart';
import '../services/joint_config.dart';
import '../widgets/glass.dart';
import '../widgets/screen_body.dart';

/// Wire the arm: drag a joint onto the pin it is plugged into.
///
/// The board keeps no map of its own, so whatever is set here is pushed down
/// the link on every connect.
class BoardScreen extends StatefulWidget {
  const BoardScreen({
    super.key,
    required this.config,
    required this.link,
    this.trailing,
  });

  final JointConfig config;
  final ArmLink link;
  final Widget? trailing;

  @override
  State<BoardScreen> createState() => _BoardScreenState();
}

class _BoardScreenState extends State<BoardScreen> {
  late final Future<BoardLayout> _layout = BoardLayout.load();

  /// The joint waiting for a pin, for people who would rather tap twice than
  /// drag.
  int? _armed;

  void _assign(int channel, int gpio) {
    final result = widget.config.assign(channel, gpio);
    setState(() => _armed = null);

    if (result == AssignResult.ok) {
      HapticFeedback.selectionClick();
      widget.link.pushMap();
      return;
    }

    final owner = widget.config.ownerOf(gpio);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      content: Text(result == AssignResult.taken && owner != null
          ? 'GPIO$gpio already drives ${widget.config.joints[owner].name}'
          : 'GPIO$gpio cannot drive a servo'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.config, widget.link]),
      builder: (context, _) {
        final config = widget.config;

        return ScreenBody(
          kicker: 'Hardware',
          title: 'Board and pins',
          trailing: widget.trailing,
          children: [
            _JointCount(config: config, onChanged: widget.link.pushMap),
            const SizedBox(height: 14),
            const GlassLabel('Drag a joint onto the pin it is wired to'),
            _Unassigned(
              config: config,
              armed: _armed,
              onArm: (channel) => setState(
                () => _armed = _armed == channel ? null : channel,
              ),
            ),
            const SizedBox(height: 14),
            FutureBuilder<BoardLayout>(
              future: _layout,
              builder: (context, snapshot) {
                final layout = snapshot.data;
                if (layout == null) {
                  return const SizedBox(
                    height: 320,
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                return _Board(
                  layout: layout,
                  config: config,
                  armed: _armed,
                  onDrop: _assign,
                  onClear: (channel) {
                    config.unassign(channel);
                    widget.link.pushMap();
                  },
                );
              },
            ),
            const SizedBox(height: 16),
            _Status(config: config, link: widget.link),
          ],
        );
      },
    );
  }
}

/// How many joints the arm has. Eight plus a gripper is the ceiling, because
/// that is how many pins can carry a servo.
class _JointCount extends StatelessWidget {
  const _JointCount({required this.config, required this.onChanged});

  final JointConfig config;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;

    void resize(int to) {
      config.resize(to);
      onChanged();
    }

    return GlassCard(
      padding: const EdgeInsets.fromLTRB(18, 14, 14, 14),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Joints',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  config.trackingUsable
                      ? 'The camera can drive this arm'
                      : 'Too many joints for the camera — sliders and steps only',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.35,
                    color: context.glassMuted,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: config.channels > 1 ? () => resize(config.channels - 1) : null,
            icon: const Icon(Icons.remove_circle_outline),
          ),
          Text('${config.channels}', style: monoStyle(size: 22, colour: accent)),
          IconButton(
            onPressed:
                config.channels < maxJoints ? () => resize(config.channels + 1) : null,
            icon: const Icon(Icons.add_circle_outline),
          ),
        ],
      ),
    );
  }
}

/// The joints with nowhere to go yet.
class _Unassigned extends StatelessWidget {
  const _Unassigned({
    required this.config,
    required this.armed,
    required this.onArm,
  });

  final JointConfig config;
  final int? armed;
  final ValueChanged<int> onArm;

  @override
  Widget build(BuildContext context) {
    final loose = [
      for (var i = 0; i < config.channels; i++)
        if (!config.joints[i].assigned) i,
    ];

    if (loose.isEmpty) {
      return Text(
        'Every joint has a pin.',
        style: TextStyle(fontSize: 12, color: context.glassMuted),
      );
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final channel in loose)
          _JointChip(
            channel: channel,
            label: config.joints[channel].name,
            armed: armed == channel,
            onTap: () => onArm(channel),
          ),
      ],
    );
  }
}

class _JointChip extends StatelessWidget {
  const _JointChip({
    required this.channel,
    required this.label,
    required this.armed,
    this.onTap,
  });

  final int channel;
  final String label;
  final bool armed;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;

    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: armed ? accent.withValues(alpha: 0.22) : context.glassFill,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: armed ? accent : context.glassStroke),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('${channel + 1}', style: monoStyle(size: 12, colour: accent)),
          const SizedBox(width: 8),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );

    return GestureDetector(
      onTap: onTap,
      child: Draggable<int>(
        data: channel,
        feedback: Material(color: Colors.transparent, child: Opacity(opacity: 0.9, child: chip)),
        childWhenDragging: Opacity(opacity: 0.35, child: chip),
        child: chip,
      ),
    );
  }
}

/// The board drawing, with a rail of pin blocks down each side.
///
/// The pins themselves are 2.54 mm apart, which is about nine logical pixels at
/// this size — far too small to drop onto. So the blocks are spread evenly down
/// the rail and a leader line joins each one to its real place on the board.
class _Board extends StatelessWidget {
  const _Board({
    required this.layout,
    required this.config,
    required this.armed,
    required this.onDrop,
    required this.onClear,
  });

  final BoardLayout layout;
  final JointConfig config;
  final int? armed;
  final void Function(int channel, int gpio) onDrop;
  final ValueChanged<int> onClear;

  static const _railWidth = 96.0;
  static const _blockHeight = 38.0;

  @override
  Widget build(BuildContext context) {
    final pins = [
      for (final gpio in allowedPins)
        if (layout.forGpio(gpio) != null) layout.forGpio(gpio)!,
    ];
    final left = pins.where((p) => p.onLeftHeader).toList()
      ..sort((a, b) => a.y.compareTo(b.y));
    final right = pins.where((p) => !p.onLeftHeader).toList()
      ..sort((a, b) => a.y.compareTo(b.y));

    return LayoutBuilder(
      builder: (context, constraints) {
        final boardWidth =
            (constraints.maxWidth - _railWidth * 2 - 16).clamp(70.0, 150.0);
        final boardHeight = boardWidth * BoardLayout.heightMm / BoardLayout.widthMm;
        final height = boardHeight.clamp(260.0, 460.0);
        final boardLeft = (constraints.maxWidth - boardWidth) / 2;

        double blockCentre(int index, int count) =>
            (index + 0.5) / count * height;

        return SizedBox(
          height: height,
          child: Stack(
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _LeaderLines(
                    left: [
                      for (var i = 0; i < left.length; i++)
                        (blockCentre(i, left.length), left[i].y / BoardLayout.heightMm * height),
                    ],
                    right: [
                      for (var i = 0; i < right.length; i++)
                        (blockCentre(i, right.length), right[i].y / BoardLayout.heightMm * height),
                    ],
                    boardLeft: boardLeft,
                    boardRight: boardLeft + boardWidth,
                    railWidth: _railWidth,
                    colour: context.glassMuted,
                  ),
                ),
              ),
              Positioned(
                left: boardLeft,
                width: boardWidth,
                height: height,
                child: SvgPicture.asset(
                  BoardLayout.svgAsset,
                  fit: BoxFit.contain,
                  alignment: Alignment.topCenter,
                ),
              ),
              for (var i = 0; i < left.length; i++)
                Positioned(
                  left: 0,
                  width: _railWidth,
                  top: blockCentre(i, left.length) - _blockHeight / 2,
                  height: _blockHeight,
                  child: _PinBlock(
                    pin: left[i],
                    config: config,
                    armed: armed,
                    onDrop: onDrop,
                    onClear: onClear,
                  ),
                ),
              for (var i = 0; i < right.length; i++)
                Positioned(
                  right: 0,
                  width: _railWidth,
                  top: blockCentre(i, right.length) - _blockHeight / 2,
                  height: _blockHeight,
                  child: _PinBlock(
                    pin: right[i],
                    config: config,
                    armed: armed,
                    onDrop: onDrop,
                    onClear: onClear,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _LeaderLines extends CustomPainter {
  const _LeaderLines({
    required this.left,
    required this.right,
    required this.boardLeft,
    required this.boardRight,
    required this.railWidth,
    required this.colour,
  });

  /// (block centre, pin position) pairs, both vertical offsets.
  final List<(double, double)> left;
  final List<(double, double)> right;
  final double boardLeft;
  final double boardRight;
  final double railWidth;
  final Color colour;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = colour.withValues(alpha: 0.5)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;

    for (final (block, pin) in left) {
      final path = Path()
        ..moveTo(railWidth, block)
        ..lineTo((railWidth + boardLeft) / 2, block)
        ..lineTo(boardLeft, pin);
      canvas.drawPath(path, paint);
      canvas.drawCircle(Offset(boardLeft, pin), 2.5, Paint()..color = colour);
    }

    for (final (block, pin) in right) {
      final path = Path()
        ..moveTo(size.width - railWidth, block)
        ..lineTo((size.width - railWidth + boardRight) / 2, block)
        ..lineTo(boardRight, pin);
      canvas.drawPath(path, paint);
      canvas.drawCircle(Offset(boardRight, pin), 2.5, Paint()..color = colour);
    }
  }

  @override
  bool shouldRepaint(_LeaderLines old) =>
      old.left != left || old.right != right || old.colour != colour;
}

/// One pin: a drop target, and the joint that landed on it.
class _PinBlock extends StatelessWidget {
  const _PinBlock({
    required this.pin,
    required this.config,
    required this.armed,
    required this.onDrop,
    required this.onClear,
  });

  final BoardPin pin;
  final JointConfig config;
  final int? armed;
  final void Function(int channel, int gpio) onDrop;
  final ValueChanged<int> onClear;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final owner = config.ownerOf(pin.gpio);
    final taken = owner != null;

    return DragTarget<int>(
      onWillAcceptWithDetails: (details) =>
          owner == null || owner == details.data,
      onAcceptWithDetails: (details) => onDrop(details.data, pin.gpio),
      builder: (context, candidate, _) {
        final hot = candidate.isNotEmpty || (armed != null && !taken);

        return GestureDetector(
          onTap: () {
            if (armed != null) {
              onDrop(armed!, pin.gpio);
            } else if (taken) {
              onClear(owner);
            }
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: taken
                  ? accent.withValues(alpha: 0.18)
                  : hot
                      ? accent.withValues(alpha: 0.1)
                      : context.glassFill,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: taken || hot ? accent : context.glassStroke,
                width: hot ? 1.6 : 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('D${pin.label}', style: monoStyle(size: 11, colour: context.glassMuted)),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    taken ? config.joints[owner].name : 'free',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: taken ? null : context.glassMuted,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// What the board says it did with the map.
class _Status extends StatelessWidget {
  const _Status({required this.config, required this.link});

  final JointConfig config;
  final ArmLink link;

  @override
  Widget build(BuildContext context) {
    final mask = link.attachedMask;
    final assigned = config.joints.where((j) => j.assigned).length;

    final String state;
    if (!link.connected) {
      state = 'Not connected — the map is pushed the moment the arm answers.';
    } else if (mask == null) {
      state = 'Connected. Waiting for the board to confirm the map.';
    } else {
      final attached = List.generate(config.channels, (i) => i)
          .where((i) => mask & (1 << i) != 0)
          .length;
      state = attached == assigned
          ? 'The board attached all $attached servos.'
          : 'The board attached $attached of $assigned servos.';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const GlassLabel('On the board'),
        GlassWell(
          child: Text(
            state,
            style: TextStyle(fontSize: 12, height: 1.4, color: context.glassMuted),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Servos draw far more current than the board can supply: power them '
          'separately and tie the grounds together. GPIO16 and GPIO17 are wired '
          'to the memory on WROVER modules and cannot drive a servo there.',
          style: TextStyle(fontSize: 12, height: 1.4, color: context.glassMuted),
        ),
      ],
    );
  }
}
