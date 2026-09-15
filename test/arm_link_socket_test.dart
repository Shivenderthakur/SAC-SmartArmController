import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_arm_controller/services/arm_link.dart';

/// Stands in for the sketch in esp32/: accepts one client, answers `ok;` to
/// every line, and can be told to go quiet — which is the interesting part,
/// because a peer that stops answering without closing is exactly the failure a
/// socket cannot report on its own.
class FakeArm {
  FakeArm._(this._server);

  final ServerSocket _server;
  final lines = <String>[];
  final _connections = <Socket>[];

  bool answering = true;

  static Future<FakeArm> start() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final arm = FakeArm._(server);
    server.listen((socket) {
      arm._connections.add(socket);
      socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        arm.lines.add(line);
        if (arm.answering) socket.write('ok;\n');
      }, onError: (_) {}, onDone: () {});
    });
    return arm;
  }

  int get port => _server.port;
  int get connections => _connections.length;

  Future<void> stop() async {
    for (final socket in _connections) {
      socket.destroy();
    }
    await _server.close();
  }
}

/// Polls [until] rather than waiting a fixed time — the link runs on real
/// timers and a sleep long enough to be reliable would make the suite crawl.
Future<bool> waitFor(bool Function() until, {Duration timeout = const Duration(seconds: 6)}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (until()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  return until();
}

void main() {
  late FakeArm arm;
  late ArmLink link;

  setUp(() async {
    arm = await FakeArm.start();
    link = ArmLink();
  });

  tearDown(() async {
    link.dispose();
    await arm.stop();
  });

  void connect({int minIntervalMs = 10}) => link.configure(
        host: '127.0.0.1:${arm.port}',
        enabled: true,
        minIntervalMs: minIntervalMs,
        transport: ArmTransport.tcp,
      );

  test('opens one connection and writes the command as a line', () async {
    connect();
    expect(await waitFor(() => link.connected), isTrue,
        reason: 'never connected');

    link.send([115, 95, 108, 60]);

    expect(await waitFor(() => arm.lines.isNotEmpty), isTrue,
        reason: 'nothing reached the arm');
    // The wire format the desktop script wrote to the serial port, unchanged,
    // with the claw mirrored onto channel 5.
    expect(arm.lines.first, '1,115;2,95;3,108;4,60;5,120;');
    expect(link.sent, 1);
    expect(link.state, LinkState.ok);
    expect(link.reconnects, 0);
  });

  test('holds the connection open across many commands', () async {
    connect();
    expect(await waitFor(() => link.connected), isTrue);

    for (var i = 0; i < 5; i++) {
      link.send([90 + i, 90, 90, 60]);
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }

    expect(await waitFor(() => link.sent >= 5), isTrue,
        reason: 'sent ${link.sent} of 5');
    expect(arm.connections, 1, reason: 'reconnected mid-stream');
  });

  test('heartbeats while idle, so silence is measurable at all', () async {
    connect();
    expect(await waitFor(() => link.connected), isTrue);

    // Nothing is being sent: whatever arrives now is the heartbeat.
    expect(await waitFor(() => arm.lines.contains('?;')), isTrue,
        reason: 'no heartbeat within the timeout');
    expect(link.state, LinkState.ok);
  });

  test('a peer that stops answering is treated as dead and rebuilt', () async {
    connect();
    expect(await waitFor(() => link.connected), isTrue);
    link.send([90, 90, 90, 60]);
    expect(await waitFor(() => link.sent >= 1), isTrue);

    // The socket stays open and writes keep succeeding — this is the failure
    // HTTP could not hide and a socket cannot see. Only the silence gives it
    // away.
    arm.answering = false;

    expect(await waitFor(() => link.reconnects >= 1), isTrue,
        reason: 'never noticed the arm had gone quiet');
    expect(link.state, LinkState.error);
    // And it does not give up: a new connection is attempted.
    expect(await waitFor(() => arm.connections >= 2), isTrue,
        reason: 'did not reconnect');
  });

  test('switching transport tears the socket down', () async {
    connect();
    expect(await waitFor(() => link.connected), isTrue);

    link.configure(
      host: '127.0.0.1:${arm.port}',
      enabled: true,
      minIntervalMs: 10,
      transport: ArmTransport.http,
    );
    expect(link.connected, isFalse);
  });

  test('turning streaming off closes the socket', () async {
    connect();
    expect(await waitFor(() => link.connected), isTrue);

    link.configure(
      host: '127.0.0.1:${arm.port}',
      enabled: false,
      minIntervalMs: 10,
      transport: ArmTransport.tcp,
    );
    expect(link.connected, isFalse);
    expect(link.state, LinkState.idle);
  });

  test('reads a port off the address, and defaults when there is none', () {
    link.configure(
      host: '192.168.1.50',
      enabled: false,
      minIntervalMs: 80,
      transport: ArmTransport.tcp,
    );
    expect(link.hostPort(), ('192.168.1.50', ArmLink.defaultTcpPort));

    link.configure(
      host: 'http://192.168.1.50:9000/',
      enabled: false,
      minIntervalMs: 80,
      transport: ArmTransport.tcp,
    );
    expect(link.hostPort(), ('192.168.1.50', 9000));
  });
}
