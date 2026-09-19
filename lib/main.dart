import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/appearance_screen.dart';
import 'screens/board_screen.dart';
import 'screens/connection_screen.dart';
import 'screens/control_screen.dart';
import 'screens/track_screen.dart';
import 'services/app_settings.dart';
import 'services/arm_controller.dart';
import 'services/arm_link.dart';
import 'services/joint_config.dart';
import 'services/tracker.dart';
import 'widgets/glass.dart';
import 'widgets/slide_nav_bar.dart';
import 'widgets/slide_selection.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  // The bar floats over the content, so the content has to reach the edges.
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  final settings = await AppSettings.load();
  final joints = await JointConfig.load();
  runApp(SmartArmApp(settings: settings, joints: joints));
}

class SmartArmApp extends StatelessWidget {
  const SmartArmApp({super.key, required this.settings, required this.joints});

  final AppSettings settings;
  final JointConfig joints;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        ThemeData theme(Brightness brightness) {
          final scheme = ColorScheme.fromSeed(
            seedColor: settings.accentColor,
            brightness: brightness,
          );
          final base = brightness == Brightness.dark
              ? AmbientBackground.baseDark
              : AmbientBackground.baseLight;

          return ThemeData(
            useMaterial3: true,
            colorScheme: scheme,
            scaffoldBackgroundColor: base,
            // Nothing in the app is a Material surface any more; the glass
            // draws its own fill over the ambient wash.
            canvasColor: Colors.transparent,
            splashColor: Colors.transparent,
            highlightColor: Colors.transparent,
            sliderTheme: SliderThemeData(
              activeTrackColor: scheme.primary,
              thumbColor: Colors.white,
              overlayColor: scheme.primary.withValues(alpha: 0.14),
            ),
          );
        }

        return MaterialApp(
          title: 'Smart Arm',
          debugShowCheckedModeBanner: false,
          themeMode: settings.themeMode,
          theme: theme(Brightness.light),
          darkTheme: theme(Brightness.dark),
          home: HomeShell(settings: settings, joints: joints),
        );
      },
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.settings, required this.joints});

  final AppSettings settings;
  final JointConfig joints;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  static const _destinations = [
    NavDestination(Icons.back_hand_outlined, 'Track'),
    NavDestination(Icons.tune, 'Control'),
    NavDestination(Icons.developer_board_outlined, 'Board'),
    NavDestination(Icons.settings_input_antenna, 'Arm'),
    NavDestination(Icons.palette_outlined, 'Theme'),
  ];

  /// One tint per screen, straight from the design. The glass stays the same
  /// everywhere; only this changes, and it changes continuously as the bar is
  /// scrubbed rather than cutting over at the boundary.
  static const _tints = [
    ScreenTint(Color(0xFFA855F7), Color(0xFFEC4899)),
    ScreenTint(Color(0xFFFB923C), Color(0xFFF43F5E)),
    ScreenTint(Color(0xFF818CF8), Color(0xFF6366F1)),
    ScreenTint(Color(0xFF22D3EE), Color(0xFF3B82F6)),
    ScreenTint(Color(0xFF34D399), Color(0xFF14B8A6)),
  ];

  late final ArmLink _link;
  late final ArmController _arm;
  late final Tracker _tracker;
  late final SlideSelection _nav;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _nav = SlideSelection(vsync: this, count: _destinations.length);
    _link = ArmLink();
    // The board keeps no map of its own, so the link asks for one every time it
    // connects, and again whenever the board says it has none.
    _link.mapProvider = () => widget.joints.pinMap;
    _arm = ArmController(_link, widget.joints);
    _tracker = Tracker(_arm.fromHand);

    widget.settings.addListener(_pushLinkSettings);
    widget.joints.addListener(_pushJointConfig);
    _pushJointConfig();
    _pushLinkSettings();
    _tracker.start();
  }

  void _pushJointConfig() {
    _link.mirrorClaw = widget.joints.mirrorClaw;
  }

  void _pushLinkSettings() {
    _link.configure(
      host: widget.settings.host,
      enabled: widget.settings.streaming,
      minIntervalMs: widget.settings.sendIntervalMs,
      transport: widget.settings.transport,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.settings.removeListener(_pushLinkSettings);
    widget.joints.removeListener(_pushJointConfig);
    _nav.dispose();
    _tracker.dispose();
    _arm.dispose();
    _link.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The camera has to be handed back when the app leaves the foreground, or
    // Android takes it away and the preview comes back dead.
    if (state == AppLifecycleState.inactive) {
      _tracker.suspend();
    } else if (state == AppLifecycleState.resumed) {
      _tracker.resume();
    }
  }

  ScreenTint get _tint {
    final p = _nav.position.clamp(0.0, _tints.length - 1.0);
    final i = p.floor().clamp(0, _tints.length - 2);
    return ScreenTint.lerp(_tints[i], _tints[i + 1], p - i);
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.settings;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final pill = _LinkPill(link: _link, settings: settings);

    final screens = [
      TrackScreen(
        tracker: _tracker,
        arm: _arm,
        settings: settings,
        trailing: pill,
      ),
      ControlScreen(arm: _arm, trailing: pill),
      BoardScreen(config: widget.joints, link: _link, trailing: pill),
      ConnectionScreen(
        settings: settings,
        link: _link,
        arm: _arm,
        trailing: pill,
      ),
      AppearanceScreen(settings: settings, trailing: pill),
    ];

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
        statusBarBrightness: dark ? Brightness.dark : Brightness.light,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness:
            dark ? Brightness.light : Brightness.dark,
      ),
      child: Scaffold(
        // The nav bar floats; the screens run underneath it.
        extendBody: true,
        body: Stack(
          children: [
            Positioned.fill(
              child: AnimatedBuilder(
                animation: _nav,
                builder: (context, _) => AmbientBackground(tint: _tint),
              ),
            ),
            for (var i = 0; i < screens.length; i++)
              Positioned.fill(child: _Page(nav: _nav, index: i, child: screens[i])),
            Positioned(
              left: 16,
              right: 16,
              bottom: MediaQuery.paddingOf(context).bottom + 14,
              child: ListenableBuilder(
                listenable: settings,
                builder: (context, _) => SlideNavBar(
                  destinations: _destinations,
                  selection: _nav,
                  accent: settings.accentColor,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One screen, positioned against the nav bar's fractional position.
///
/// All four stay mounted — the camera preview must not be torn down and rebuilt
/// every time a tab is touched — but only the one or two either side of the
/// thumb are painted, and they slide and fade against each other as it moves.
/// At rest both the opacity and the transform are identities, so this costs
/// nothing once the spring has settled.
class _Page extends StatelessWidget {
  const _Page({required this.nav, required this.index, required this.child});

  final SlideSelection nav;
  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;

    return AnimatedBuilder(
      animation: nav,
      child: child,
      builder: (context, child) {
        final distance = index - nav.position;
        final away = distance.abs();

        return Offstage(
          offstage: away >= 1,
          child: IgnorePointer(
            ignoring: away > 0.02,
            child: Opacity(
              opacity: (1 - away * 1.35).clamp(0.0, 1.0),
              child: Transform.translate(
                offset: Offset(-distance * width * 0.22, 0),
                child: child,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Live state of the arm link, in the header of every screen.
class _LinkPill extends StatelessWidget {
  const _LinkPill({required this.link, required this.settings});

  final ArmLink link;
  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([link, settings]),
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;

        final (label, colour) = switch (link) {
          _ when !settings.streaming => ('offline', context.glassMuted),
          _ when settings.host.isEmpty => ('no address', scheme.error),
          _ when link.state == LinkState.error => ('error', scheme.error),
          _ when link.state == LinkState.ok => ('live', const Color(0xFF34D399)),
          _ => ('idle', context.glassMuted),
        };

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          decoration: BoxDecoration(
            color: colour.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: colour.withValues(alpha: 0.3)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(color: colour, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: colour,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
