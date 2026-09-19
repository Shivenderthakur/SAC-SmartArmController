import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

enum LinkState { idle, sending, ok, error }

/// How the commands reach the arm.
///
/// [http] opens a connection per command: slower, but a failure is immediate
/// and unmistakable, because every command carries its own timeout.
///
/// [tcp] holds one connection open and writes the same line down it. It is
/// several times faster — no handshake, no headers, no new socket every 80 ms —
/// but it gives up the thing HTTP gave away for free: a write into a socket
/// whose peer has vanished *succeeds*. It lands in the kernel's send buffer and
/// the kernel retransmits, quietly, for tens of seconds. Nothing fails, so the
/// app would happily report "live" while the arm sat still. Everything below
/// about heartbeats, silence and reconnection exists to buy that back.
enum ArmTransport { http, tcp }

/// Pushes servo angles to an ESP32 on the local network.
///
/// The desktop script wrote `"{channel},{angle};"` down a serial port. The phone
/// has no serial port, so the same command string goes over the network
/// instead — unchanged, so a sketch that drove the arm from serial needs almost
/// no rewriting:
///
///     GET http://<host>/servo?cmd=1,115;2,95;3,108;4,60;5,120;
///     or, down an open socket to <host>:3333, the same string and a newline.
///
/// Channel 5 mirrors the claw (`180 - angle`) exactly as the desktop script did
/// for the second gripper servo.
class ArmLink extends ChangeNotifier {
  ArmLink();

  static const defaultTcpPort = 3333;

  /// Silence that means the socket is gone. The arm answers every command and
  /// every heartbeat, so nothing heard for this long is the only evidence a
  /// dead connection ever gives.
  static const _deadAfter = Duration(seconds: 3);
  static const _heartbeatEvery = Duration(milliseconds: 700);
  static const _idleBefore = Duration(milliseconds: 900);
  static const _minBackoffMs = 300;
  static const _maxBackoffMs = 5000;

  final _client = HttpClient()..connectionTimeout = const Duration(seconds: 2);

  String _host = '';
  int _minIntervalMs = 80;
  bool _enabled = false;
  ArmTransport _transport = ArmTransport.http;

  bool _inFlight = false;
  DateTime _lastSent = DateTime.fromMillisecondsSinceEpoch(0);
  List<int>? _pending;

  Socket? _socket;
  String _replies = '';
  bool _connecting = false;
  Timer? _beat;
  Timer? _retry;
  Completer<void>? _probe;
  DateTime _lastHeard = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? _awaiting;
  int _backoffMs = _minBackoffMs;

  LinkState state = LinkState.idle;
  String message = 'not connected';
  int sent = 0;
  int failed = 0;

  /// How many times the socket has had to be rebuilt. On a good WiFi this stays
  /// at zero; if it climbs while the arm is idle, the link is the problem.
  int reconnects = 0;

  Duration? lastLatency;

  bool _disposed = false;

  bool get enabled => _enabled;
  bool get configured => _host.isNotEmpty;
  ArmTransport get transport => _transport;
  bool get connected => _socket != null;

  void configure({
    required String host,
    required bool enabled,
    required int minIntervalMs,
    ArmTransport transport = ArmTransport.http,
  }) {
    final next = host.trim();
    final moved =
        next != _host || transport != _transport || enabled != _enabled;

    _host = next;
    _enabled = enabled;
    _minIntervalMs = minIntervalMs;
    _transport = transport;

    if (moved) {
      // Whatever was open, it is not the right connection any more.
      _dropSocket();
      if (_wantsSocket) {
        state = LinkState.sending;
        message = 'connecting…';
        unawaited(_ensureConnected());
      }
    }

    if (!_enabled || _host.isEmpty) {
      state = LinkState.idle;
      message = _host.isEmpty ? 'no address set' : 'streaming off';
    }
    notifyListeners();
  }

  bool get _wantsSocket =>
      _enabled && _transport == ArmTransport.tcp && _host.isNotEmpty;

  /// [mirrorClaw] appends channel 5 as the opposite of channel 4, for a gripper
  /// built from two opposed servos. It is only safe on an arm of four joints or
  /// fewer: past that, channel 5 is a real servo and its own mirror would
  /// overwrite it on every command.
  static String command(List<int> angles, {bool mirrorClaw = false}) {
    final b = StringBuffer();
    for (var i = 0; i < angles.length; i++) {
      b.write('${i + 1},${angles[i]};');
    }
    if (mirrorClaw && angles.length == 4) b.write('5,${180 - angles[3]};');
    return b.toString();
  }

  /// `M,<channel>,<gpio>;` per channel, -1 for a joint with no pin. The board
  /// takes the whole line or none of it.
  static String mapLine(List<int> pins) {
    final b = StringBuffer();
    for (var i = 0; i < pins.length; i++) {
      b.write('M,${i + 1},${pins[i]};');
    }
    return b.toString();
  }

  /// Where the pin map comes from. The board keeps it in RAM only, so the link
  /// pushes it on every connect and again whenever the board says it has none.
  List<int> Function()? mapProvider;

  /// Whether to mirror the claw onto channel 5 — set from the joint config.
  bool mirrorClaw = false;

  /// The channels the board reported as attached, as a bitmask, or null before
  /// it has answered.
  int? attachedMask;

  /// Sent outside the coalescing queue in [send]: a dropped angle is replaced by
  /// the next frame, but a dropped map leaves the arm wired to nothing.
  void pushMap() {
    final pins = mapProvider?.call();
    if (pins == null || pins.isEmpty) return;

    if (_transport == ArmTransport.tcp) {
      _writeLine(mapLine(pins));
    } else {
      unawaited(_sendMapOverHttp(mapLine(pins)));
    }
  }

  Future<void> _sendMapOverHttp(String line) async {
    try {
      final request = await _client.getUrl(_uri(line)).timeout(
            const Duration(seconds: 2),
          );
      final response = await request.close().timeout(const Duration(seconds: 2));
      await response.drain<void>();
    } catch (_) {
      // The next command carries the board's mask, which re-triggers this.
    }
  }

  /// Splits `192.168.1.50:3333` — and tolerates a pasted `http://…/` URL,
  /// because the same field feeds both transports.
  (String, int) hostPort() {
    var h = _host.replaceFirst(RegExp('^https?://'), '').split('/').first;
    final colon = h.lastIndexOf(':');
    if (colon > 0) {
      final port = int.tryParse(h.substring(colon + 1));
      if (port != null) return (h.substring(0, colon), port);
    }
    return (h, defaultTcpPort);
  }

  Uri _uri(String cmd) {
    var host = _host;
    if (!host.startsWith('http://') && !host.startsWith('https://')) {
      host = 'http://$host';
    }
    return Uri.parse(host).replace(path: '/servo', queryParameters: {'cmd': cmd});
  }

  /// Queues [angles]. Coalescing is deliberate: only the newest position
  /// matters, so a value that arrives while one is in flight replaces the one
  /// waiting rather than queueing behind it.
  void send(List<int> angles) {
    if (!_enabled || _host.isEmpty) return;
    _pending = List<int>.of(angles);
    unawaited(_drain());
  }

  Future<void> _drain() async {
    if (_inFlight || _pending == null) return;
    final since = DateTime.now().difference(_lastSent).inMilliseconds;
    if (since < _minIntervalMs) {
      Timer(Duration(milliseconds: _minIntervalMs - since), _drain);
      return;
    }

    final angles = _pending!;
    _pending = null;
    _lastSent = DateTime.now();

    if (_transport == ArmTransport.tcp) {
      await _sendOverSocket(angles);
    } else {
      await _sendOverHttp(angles);
    }
  }

  // ---------------------------------------------------------------- socket

  Future<void> _ensureConnected() async {
    if (_disposed || _socket != null || _connecting || !_wantsSocket) return;
    _connecting = true;

    final (host, port) = hostPort();
    try {
      final socket =
          await Socket.connect(host, port, timeout: const Duration(seconds: 3));
      // Angles are tiny and late is worse than often: never sit on one waiting
      // for company.
      socket.setOption(SocketOption.tcpNoDelay, true);

      _socket = socket;
      _lastHeard = DateTime.now();
      _backoffMs = _minBackoffMs;
      socket.listen(
        _heard,
        onError: (Object e) => _lost(_short(e)),
        onDone: () => _lost('closed by the arm'),
        cancelOnError: true,
      );
      _beat ??= Timer.periodic(_heartbeatEvery, (_) => _tick());

      // Before any angle: a board that rebooted is holding no map at all.
      pushMap();

      state = LinkState.ok;
      message = 'socket open to $host:$port';
    } catch (e) {
      _socket = null;
      state = LinkState.error;
      message = _short(e);
      _scheduleRetry();
    } finally {
      _connecting = false;
      notifyListeners();
    }
  }

  /// Anything at all coming back is proof of life. The content matters too: the
  /// board answers the heartbeat with `ok,0;` while it holds no pin map, which
  /// is the only sign a phone gets that the board rebooted under a socket that
  /// survived.
  void _heard(List<int> data) {
    if (_disposed) return;
    _lastHeard = DateTime.now();
    if (!(_probe?.isCompleted ?? true)) _probe!.complete();

    _replies += String.fromCharCodes(data);
    while (_replies.contains('\n')) {
      final cut = _replies.indexOf('\n');
      final line = _replies.substring(0, cut).trim();
      _replies = _replies.substring(cut + 1);
      if (line.isEmpty) continue;

      if (line.startsWith('ok,0')) {
        pushMap();
      } else if (line.startsWith('map,')) {
        attachedMask =
            int.tryParse(line.substring(4).replaceAll(';', ''), radix: 16);
      }
    }
    if (_replies.length > 256) _replies = '';

    final at = _awaiting;
    if (at == null) return;
    _awaiting = null;
    lastLatency = DateTime.now().difference(at);
    state = LinkState.ok;
    message = 'ok — ${lastLatency!.inMilliseconds} ms';
    notifyListeners();
  }

  /// The whole point of the heartbeat: prove the socket still reaches the arm.
  ///
  /// Nothing else can. `dart:io` exposes no `SO_KEEPALIVE`, and a write cannot
  /// report a peer that stopped listening, so silence is the signal.
  void _tick() {
    if (_disposed || !_wantsSocket) return;
    if (_socket == null) {
      unawaited(_ensureConnected());
      return;
    }

    if (DateTime.now().difference(_lastHeard) > _deadAfter) {
      _lost('no answer — reconnecting');
      return;
    }
    if (DateTime.now().difference(_lastSent) > _idleBefore) {
      _writeLine('?;');
    }
  }

  Future<void> _sendOverSocket(List<int> angles) async {
    final socket = _socket;
    if (socket == null) {
      unawaited(_ensureConnected());
      return;
    }

    _inFlight = true;
    try {
      socket.write('${command(angles, mirrorClaw: mirrorClaw)}\n');
      // Gate the next command on this one actually leaving. `Socket.add` will
      // otherwise buffer in memory without complaint, and a backlog of stale
      // angles is worse than no angles at all.
      await socket.flush();
      sent++;
      _awaiting ??= DateTime.now();
      if (state != LinkState.ok) {
        state = LinkState.ok;
        message = 'streaming';
      }
    } catch (e) {
      _lost(_short(e));
    } finally {
      _inFlight = false;
      notifyListeners();
      if (_pending != null) unawaited(_drain());
    }
  }

  void _writeLine(String line) {
    final socket = _socket;
    if (socket == null) return;
    try {
      socket.write('$line\n');
      _awaiting ??= DateTime.now();
    } catch (e) {
      _lost(_short(e));
    }
  }

  void _lost(String why) {
    if (_disposed) return;
    final had = _socket != null;
    _dropSocket();
    if (had) {
      failed++;
      reconnects++;
      state = LinkState.error;
      message = why;
      notifyListeners();
    }
    _scheduleRetry();
  }

  void _dropSocket() {
    _beat?.cancel();
    _beat = null;
    _retry?.cancel();
    _retry = null;
    _awaiting = null;
    _inFlight = false;
    final socket = _socket;
    _socket = null;
    socket?.destroy();
  }

  /// Backing off matters: an ESP32 that is rebooting refuses connections for a
  /// second or two, and hammering it every 300 ms neither helps it nor the WiFi.
  void _scheduleRetry() {
    if (_disposed || !_wantsSocket) return;
    _retry?.cancel();
    _retry = Timer(Duration(milliseconds: _backoffMs), () {
      unawaited(_ensureConnected());
    });
    _backoffMs = (_backoffMs * 2).clamp(_minBackoffMs, _maxBackoffMs);
  }

  // ------------------------------------------------------------------ http

  Future<void> _sendOverHttp(List<int> angles) async {
    _inFlight = true;
    final started = DateTime.now();

    try {
      final request = await _client
          .getUrl(_uri(command(angles, mirrorClaw: mirrorClaw)))
          .timeout(const Duration(seconds: 2));
      final response = await request.close().timeout(const Duration(seconds: 2));
      await response.drain<void>();

      lastLatency = DateTime.now().difference(started);
      if (response.statusCode == 200) {
        sent++;
        state = LinkState.ok;
        message = 'ok — ${lastLatency!.inMilliseconds} ms';
      } else {
        failed++;
        state = LinkState.error;
        message = 'HTTP ${response.statusCode}';
      }
    } catch (e) {
      failed++;
      state = LinkState.error;
      message = _short(e);
    } finally {
      _inFlight = false;
      notifyListeners();
      if (_pending != null) unawaited(_drain());
    }
  }

  // ------------------------------------------------------------------ ping

  /// One-shot reachability check for the Arm screen.
  Future<String> ping() async {
    if (_host.isEmpty) return 'No address set.';
    return _transport == ArmTransport.tcp ? _pingSocket() : _pingHttp();
  }

  Future<String> _pingSocket() async {
    final (host, port) = hostPort();

    // Probe down the open socket rather than opening a second one — the sketch
    // serves one client, and a second connection would evict the live one.
    if (_socket != null) {
      final started = DateTime.now();
      _probe = Completer<void>();
      _writeLine('?;');
      try {
        await _probe!.future.timeout(const Duration(seconds: 2));
        final ms = DateTime.now().difference(started).inMilliseconds;
        return 'Answered down the open socket in $ms ms.';
      } on TimeoutException {
        return 'The socket to $host:$port is open but the arm did not answer. '
            'It may have rebooted — the link will notice within three seconds '
            'and rebuild it.';
      } finally {
        _probe = null;
      }
    }

    final started = DateTime.now();
    try {
      final probe =
          await Socket.connect(host, port, timeout: const Duration(seconds: 3));
      final ms = DateTime.now().difference(started).inMilliseconds;
      probe.destroy();
      if (_wantsSocket) unawaited(_ensureConnected());
      return 'Connected to $host:$port in $ms ms.';
    } catch (e) {
      return 'No answer from $host:$port — ${_short(e)}. The sketch in esp32/ '
          'has to be reflashed for the socket transport.';
    }
  }

  Future<String> _pingHttp() async {
    final started = DateTime.now();
    try {
      final request = await _client
          .getUrl(_uri(command(mapProvider?.call().map((_) => 90).toList() ??
              const [90, 90, 90, 60])))
          .timeout(const Duration(seconds: 3));
      final response = await request.close().timeout(const Duration(seconds: 3));
      await response.drain<void>();
      final ms = DateTime.now().difference(started).inMilliseconds;
      return response.statusCode == 200
          ? 'Reached the arm in $ms ms.'
          : 'Answered with HTTP ${response.statusCode} in $ms ms.';
    } catch (e) {
      return 'No answer: ${_short(e)}';
    }
  }

  static String _short(Object e) {
    if (e is SocketException) return 'unreachable';
    if (e is TimeoutException) return 'timed out';
    if (e is FormatException) return 'bad address';
    final s = e.toString();
    return s.length > 60 ? '${s.substring(0, 60)}…' : s;
  }

  @override
  void dispose() {
    _disposed = true;
    _dropSocket();
    _client.close(force: true);
    super.dispose();
  }
}
