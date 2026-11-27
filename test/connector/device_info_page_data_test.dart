import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/review_mode/review_frames.dart';
import 'package:meshcore_open/review_mode/review_radio.dart';
import 'package:meshcore_open/review_mode/review_script.dart';
import 'package:meshcore_open/services/usb_serial_frame_codec.dart';
import 'package:meshcore_open/storage/last_radio_store.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _waitFor(bool Function() condition, {int seconds = 8}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (!condition()) {
    if (DateTime.now().isAfter(end)) fail('Timed out waiting for condition');
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

/// RESP_CODE_DEVICE_INFO laid out as firmware MyMesh.cpp writes it.
Uint8List _deviceInfo({
  int verCode = 10,
  int pin = 0,
  String buildDate = '',
  String manufacturer = 'Heltec V3',
  String version = 'v1.10.0',
}) {
  final frame = Uint8List(82);
  frame[0] = respCodeDeviceInfo;
  frame[1] = verCode;
  frame[2] = ReviewScript.maxContacts ~/ 2;
  frame[3] = ReviewScript.maxChannels;
  ByteData.sublistView(frame).setUint32(4, pin, Endian.little);
  frame.setAll(8, ascii.encode(buildDate));
  frame.setAll(20, ascii.encode(manufacturer));
  frame.setAll(60, ascii.encode(version));
  return frame;
}

/// RESP_CODE_STATS / STATS_TYPE_CORE as firmware writes it.
Uint8List _coreStats({required int uptimeSecs, int millivolts = 4100}) {
  final data = ByteData(11);
  data.setUint8(0, respCodeStats);
  data.setUint8(1, statsTypeCore);
  data.setUint16(2, millivolts, Endian.little);
  data.setUint32(4, uptimeSecs, Endian.little);
  data.setUint16(8, 0, Endian.little); // err_flags
  data.setUint8(10, 0); // queue_len
  return data.buffer.asUint8List();
}

Uint8List _currTime(int epochSecs) {
  final data = ByteData(5);
  data.setUint8(0, respCodeCurrTime);
  data.setUint32(1, epochSecs, Endian.little);
  return data.buffer.asUint8List();
}

/// Review radio that records what the app sends and can answer DEVICE_INFO
/// with a fixed PIN and build date.
class _TestRadio extends ReviewRadio {
  _TestRadio({super.firmwareVerCode, this.deviceInfo})
    : super(
        scheduledMessageInterval: const Duration(hours: 1),
        ackDelay: const Duration(milliseconds: 50),
        replyDelay: const Duration(hours: 1),
      );

  final Uint8List? deviceInfo;
  final List<Uint8List> sent = [];

  @override
  void handle(Uint8List frame) {
    sent.add(Uint8List.fromList(frame));
    final info = deviceInfo;
    if (info != null && frame.isNotEmpty && frame[0] == cmdDeviceQuery) {
      emitForTest(info);
      return;
    }
    super.handle(frame);
  }

  Iterable<Uint8List> withCode(int code) =>
      sent.where((f) => f.isNotEmpty && f[0] == code);
}

/// A companion over loopback TCP backed by a [ReviewRadio].
class _TcpCompanion {
  late final ServerSocket _server;
  final List<Socket> _clients = [];
  final List<ReviewRadio> _radios = [];

  int get port => _server.port;

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((socket) {
      _clients.add(socket);
      var closed = false;
      unawaited(
        socket.done.catchError((_) {}).whenComplete(() => closed = true),
      );
      final radio = ReviewRadio(
        scheduledMessageInterval: const Duration(hours: 1),
        replyDelay: const Duration(hours: 1),
      );
      _radios.add(radio);
      radio.frames.listen((payload) {
        if (closed) return;
        final length = payload.length;
        try {
          socket.add([
            usbSerialRxFrameStart,
            length & 0xFF,
            (length >> 8) & 0xFF,
            ...payload,
          ]);
        } catch (_) {}
      });
      final decoder = UsbSerialFrameDecoder();
      socket.listen(
        (bytes) {
          for (final packet in decoder.ingest(Uint8List.fromList(bytes))) {
            radio.handle(packet.payload);
          }
        },
        onError: (_) {},
        onDone: () => closed = true,
        cancelOnError: true,
      );
    });
  }

  Future<void> close() async {
    for (final socket in _clients) {
      socket.destroy();
    }
    _clients.clear();
    for (final radio in _radios) {
      radio.dispose();
    }
    await _server.close();
  }
}

// initialize() listens to the notification service's single-subscription
// reply stream, so these connectors run without it.
MeshCoreConnector _newConnector() {
  final connector = MeshCoreConnector();
  addTearDown(connector.dispose);
  return connector;
}

Future<MeshCoreConnector> _connectReview(_TestRadio radio) async {
  final connector = _newConnector();
  connector.reviewRadioFactoryForTest = () => radio;
  await connector.connectReview();
  addTearDown(connector.disconnect);
  await _waitFor(() => connector.selfPublicKey != null);
  return connector;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
  });

  group('DEVICE_INFO', () {
    test('reads the saved BLE PIN and the build date', () {
      final connector = _newConnector();
      connector.handleFrameForTest(
        _deviceInfo(pin: 123456, buildDate: '15 Oct 2026'),
      );

      expect(connector.blePin, 123456);
      expect(connector.firmwareBuildDate, '15 Oct 2026');
      // The fields around them still read from their own offsets.
      expect(connector.firmwareVerCode, 10);
      expect(connector.manufacturerName, 'Heltec V3');
      expect(connector.firmwareVersionString, 'v1.10.0');
    });

    test('PIN 0 and an empty build date mean no fixed PIN and no date', () {
      final connector = _newConnector();
      connector.handleFrameForTest(_deviceInfo());

      expect(connector.blePin, 0);
      expect(connector.firmwareBuildDate, isNull);
      expect(connector.manufacturerName, 'Heltec V3');
    });

    test('a frame that ends before the PIN leaves both unset', () {
      final connector = _newConnector();
      connector.handleFrameForTest([respCodeDeviceInfo, 3, 50, 8]);

      expect(connector.firmwareVerCode, 3);
      expect(connector.blePin, isNull);
      expect(connector.firmwareBuildDate, isNull);
    });

    test('a frame that ends after the PIN has the PIN but no date', () {
      final connector = _newConnector();
      connector.handleFrameForTest(
        _deviceInfo(pin: 123456, buildDate: '15 Oct 2026').sublist(0, 8),
      );

      expect(connector.blePin, 123456);
      expect(connector.firmwareBuildDate, isNull);
      expect(connector.manufacturerName, isNull);
    });

    test('the PIN and date from the radio are cleared on disconnect', () async {
      final radio = _TestRadio(
        deviceInfo: _deviceInfo(
          verCode: ReviewScript.firmwareVerCode,
          pin: 654321,
          buildDate: '1 Nov 2026',
        ),
      );
      final connector = await _connectReview(radio);

      expect(connector.blePin, 654321);
      expect(connector.firmwareBuildDate, '1 Nov 2026');

      await connector.disconnect();

      expect(connector.blePin, isNull);
      expect(connector.firmwareBuildDate, isNull);
    });
  });

  group('core stats', () {
    test('uptime sets radioStartedAt to now minus the uptime', () {
      final connector = _newConnector();
      const uptime = Duration(hours: 49, minutes: 12, seconds: 7);

      final before = DateTime.now();
      connector.handleFrameForTest(_coreStats(uptimeSecs: uptime.inSeconds));
      final after = DateTime.now();

      final startedAt = connector.radioStartedAt!;
      expect(startedAt.isBefore(before.subtract(uptime)), isFalse);
      expect(startedAt.isAfter(after.subtract(uptime)), isFalse);
    });

    test('radio stats leave radioStartedAt alone and still parse', () {
      final connector = _newConnector();
      connector.handleFrameForTest(
        ReviewFrames.radioStats(
          noiseFloorDbm: -112,
          lastRssiDbm: -78,
          lastSnrQuarterDb: 38,
          txAirSecs: 12,
          rxAirSecs: 48,
        ),
      );

      expect(connector.radioStartedAt, isNull);
      expect(connector.latestRadioStats?.rxAirSecs, 48);
    });

    test('a core stats frame too short for the uptime is ignored', () {
      final connector = _newConnector();
      connector.handleFrameForTest(_coreStats(uptimeSecs: 3600).sublist(0, 7));

      expect(connector.radioStartedAt, isNull);
    });

    test('review mode matches the firmware STATS_TYPE_CORE layout', () {
      expect(
        ReviewFrames.coreStats(millivolts: 3980, uptimeSecs: 86461),
        _coreStats(uptimeSecs: 86461, millivolts: 3980),
      );
    });
  });

  group('CURR_TIME', () {
    // The radio sends whole seconds, so the offset is measured from the
    // middle of that second: radio secs * 1000 + 500 - phone ms.
    Duration readOffset(int radioSecsFromNow) {
      final connector = _newConnector();
      final before = DateTime.now().millisecondsSinceEpoch;
      final radioSecs = before ~/ 1000 + radioSecsFromNow;
      connector.handleFrameForTest(_currTime(radioSecs));
      final after = DateTime.now().millisecondsSinceEpoch;

      final offset = connector.radioClockOffset!;
      final radioMs = radioSecs * 1000 + 500;
      expect(
        offset.inMilliseconds,
        inInclusiveRange(radioMs - after, radioMs - before),
      );
      return offset;
    }

    test('a radio clock behind the phone gives a negative offset', () {
      final offset = readOffset(-120);
      expect(offset.isNegative, isTrue);
      expect(offset.inSeconds, inInclusiveRange(-121, -119));
    });

    test('a radio clock ahead of the phone gives a positive offset', () {
      final offset = readOffset(3600);
      expect(offset.isNegative, isFalse);
      expect(offset.inSeconds, inInclusiveRange(3599, 3601));
    });

    test('a radio clock in the same second reads within half a second', () {
      final offset = readOffset(0);
      expect(offset.inMilliseconds.abs(), lessThanOrEqualTo(500 + 50));
    });

    test('a frame without the full time is ignored', () {
      final connector = _newConnector();
      connector.handleFrameForTest(_currTime(1800000000).sublist(0, 4));

      expect(connector.radioClockOffset, isNull);
    });
  });

  group('connected session', () {
    test('connectedAt is set on connect and cleared on disconnect', () async {
      final connector = _newConnector();
      connector.reviewRadioFactoryForTest = () => _TestRadio();
      expect(connector.connectedAt, isNull);

      final before = DateTime.now();
      await connector.connectReview();
      addTearDown(connector.disconnect);
      final after = DateTime.now();

      final connectedAt = connector.connectedAt!;
      expect(connectedAt.isBefore(before), isFalse);
      expect(connectedAt.isAfter(after), isFalse);

      await connector.disconnect();
      expect(connector.connectedAt, isNull);
    });

    test('review mode answers core stats and the device time, and both are '
        'cleared on disconnect', () async {
      final radio = _TestRadio();
      final connector = await _connectReview(radio);
      expect(connector.radioStartedAt, isNull);
      expect(connector.radioClockOffset, isNull);

      radio.sent.clear();
      await connector.requestCoreStats();
      await connector.requestDeviceTime();
      await _waitFor(
        () =>
            connector.radioStartedAt != null &&
            connector.radioClockOffset != null,
      );

      expect(radio.withCode(cmdGetStats).map((f) => f.toList()), [
        [cmdGetStats, statsTypeCore],
      ]);
      expect(radio.withCode(cmdGetDeviceTime).map((f) => f.toList()), [
        [cmdGetDeviceTime],
      ]);
      // The review radio was created moments ago.
      final startedAgo = DateTime.now().difference(connector.radioStartedAt!);
      expect(startedAgo.inSeconds, inInclusiveRange(0, 10));
      // Review mode syncs its clock to the phone on connect.
      expect(
        connector.radioClockOffset!.inMilliseconds.abs(),
        lessThanOrEqualTo(1500),
      );

      await connector.disconnect();
      expect(connector.radioStartedAt, isNull);
      expect(connector.radioClockOffset, isNull);
    });

    test('nothing is requested while disconnected', () async {
      final radio = _TestRadio();
      final connector = await _connectReview(radio);
      await connector.disconnect();
      radio.sent.clear();

      await connector.requestCoreStats();
      await connector.requestDeviceTime();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(radio.sent, isEmpty);
      expect(connector.radioStartedAt, isNull);
      expect(connector.radioClockOffset, isNull);
    });

    test('a connector that never connected requests nothing', () async {
      final connector = _newConnector();

      await connector.requestCoreStats();
      await connector.requestDeviceTime();

      expect(connector.radioStartedAt, isNull);
      expect(connector.radioClockOffset, isNull);
    });

    test('core stats are not requested from firmware older than v8', () async {
      final radio = _TestRadio(firmwareVerCode: 7);
      final connector = await _connectReview(radio);
      await _waitFor(() => connector.firmwareVerCode == 7);
      expect(connector.supportsCompanionRadioStats, isFalse);

      radio.sent.clear();
      await connector.requestCoreStats();
      await connector.requestDeviceTime();
      await _waitFor(() => connector.radioClockOffset != null);

      expect(radio.withCode(cmdGetStats), isEmpty);
      expect(connector.radioStartedAt, isNull);
    });
  });

  group('remembered radio', () {
    test('ending a TCP link moves savedAt to the disconnect time', () async {
      final companion = _TcpCompanion();
      await companion.start();
      addTearDown(companion.close);
      final connector = _newConnector();
      addTearDown(connector.disconnect);
      final host = InternetAddress.loopbackIPv4.address;

      await connector.connectTcp(host: host, port: companion.port);
      final atConnect = LastRadioStore().load()!;
      expect(atConnect.publicKeyHex, ReviewRadio.selfPublicKeyHex);

      await Future<void>.delayed(const Duration(milliseconds: 50));
      final before = DateTime.now().millisecondsSinceEpoch;
      await connector.disconnect();
      final after = DateTime.now().millisecondsSinceEpoch;

      final stored = LastRadioStore().load()!;
      expect(
        stored.savedAt.millisecondsSinceEpoch,
        inInclusiveRange(before, after),
      );
      expect(stored.savedAt.isAfter(atConnect.savedAt), isTrue);
      // The store keeps milliseconds.
      expect(
        connector.lastRadio?.savedAt.millisecondsSinceEpoch,
        stored.savedAt.millisecondsSinceEpoch,
      );
      // Everything else is kept.
      expect(
        stored.toJson()..remove('savedAt'),
        atConnect.toJson()..remove('savedAt'),
      );
      expect(stored.transport, LastRadio.transportTcp);
      expect(stored.tcpHost, host);
      expect(stored.tcpPort, companion.port);
    });

    test('a TCP link that drops also moves savedAt', () async {
      final companion = _TcpCompanion();
      await companion.start();
      final connector = _newConnector();
      addTearDown(connector.disconnect);

      await connector.connectTcp(
        host: InternetAddress.loopbackIPv4.address,
        port: companion.port,
      );
      final atConnect = LastRadioStore().load()!;
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // The companion goes away, so the auto-reconnect cannot replace it.
      final before = DateTime.now().millisecondsSinceEpoch;
      await companion.close();
      await _waitFor(
        () => connector.state == MeshCoreConnectionState.disconnected,
      );
      final after = DateTime.now().millisecondsSinceEpoch;

      final stored = LastRadioStore().load()!;
      expect(stored.publicKeyHex, atConnect.publicKeyHex);
      expect(
        stored.savedAt.millisecondsSinceEpoch,
        inInclusiveRange(before, after),
      );
      expect(connector.connectedAt, isNull);
    });

    test('a session with a different radio leaves savedAt alone', () async {
      final otherKeyHex = 'a0' * 32;
      final savedAt = DateTime.fromMillisecondsSinceEpoch(1700000000000);
      await LastRadioStore().save(
        LastRadio(
          publicKeyHex: otherKeyHex,
          name: 'Base',
          transport: LastRadio.transportBle,
          bleRemoteId: 'AA:BB:CC:DD:EE:FF',
          savedAt: savedAt,
        ),
      );
      final connector = _newConnector();
      await connector.restoreLastRadio();
      connector.reviewRadioFactoryForTest = () => _TestRadio();

      await connector.connectReview();
      addTearDown(connector.disconnect);
      await _waitFor(() => connector.selfPublicKey != null);
      await connector.disconnect();

      final stored = LastRadioStore().load()!;
      expect(stored.publicKeyHex, otherKeyHex);
      expect(stored.savedAt, savedAt);
      expect(connector.lastRadio?.savedAt, savedAt);
    });
  });
}
