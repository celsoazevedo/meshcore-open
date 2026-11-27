import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/review_mode/review_radio.dart';
import 'package:meshcore_open/review_mode/review_script.dart';
import 'package:meshcore_open/screens/device_info_screen.dart';
import 'package:meshcore_open/screens/settings_screen.dart';
import 'package:meshcore_open/screens/share_contact_screen.dart';
import 'package:meshcore_open/services/app_debug_log_service.dart';
import 'package:meshcore_open/services/app_settings_service.dart';
import 'package:meshcore_open/services/ble_debug_log_service.dart';
import 'package:meshcore_open/services/message_retry_service.dart';
import 'package:meshcore_open/services/path_history_service.dart';
import 'package:meshcore_open/services/storage_service.dart';
import 'package:meshcore_open/services/translation_service.dart';
import 'package:meshcore_open/services/ui_view_state_service.dart';
import 'package:meshcore_open/storage/last_radio_store.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:meshcore_open/theme/mesh_theme.dart';
import 'package:meshcore_open/widgets/mesh_ui.dart';
import 'package:meshcore_open/widgets/qr_code_display.dart';
import 'package:meshcore_open/widgets/sync_progress_overlay.dart';

final _l10n = lookupAppLocalizations(const Locale('en'));
final _key = Uint8List.fromList(List<int>.generate(32, (i) => 0x7F - i));
const _pin = 482913;

/// A radio on a Bluetooth link (or the one last connected) with fixed
/// values. Records what the page asks for instead of sending it.
class _FakeRadio extends MeshCoreConnector {
  final bool connected;
  final int? pin;
  final LastRadio? fakeLastRadio;
  final DateTime _since = DateTime.now().subtract(
    const Duration(hours: 2, minutes: 28),
  );
  final DateTime _started = DateTime.now().subtract(
    const Duration(days: 3, hours: 4),
  );

  /// Command codes of the frames sent, and the page's own requests.
  final List<int> sent = [];
  final List<String> asked = [];

  _FakeRadio({this.connected = true, this.pin, this.fakeLastRadio});

  @override
  bool get isConnected => connected;
  @override
  MeshCoreTransportType get activeTransport => MeshCoreTransportType.bluetooth;
  @override
  String? get deviceId => connected ? 'D4:3A:2C:91:7E:05' : null;
  @override
  int? get blePin => connected ? pin : null;
  @override
  Uint8List? get selfPublicKey => connected ? _key : null;
  @override
  String get selfPublicKeyHex => connected ? pubKeyToHex(_key) : '';
  @override
  String get deviceDisplayName => connected ? 'Harbour Node' : 'Unknown';
  @override
  LastRadio? get lastRadio => fakeLastRadio;
  @override
  String? get lastRadioName => fakeLastRadio?.name;
  @override
  DateTime? get connectedAt => connected ? _since : null;
  @override
  Duration? get radioClockOffset =>
      connected ? const Duration(seconds: -2) : null;
  @override
  String? get manufacturerName => connected ? 'Heltec V3' : null;
  @override
  String? get firmwareVersionString => connected ? 'v1.18.0' : null;
  @override
  String? get firmwareBuildDate => connected ? '15 Oct 2026' : null;
  @override
  int? get batteryMillivolts => connected ? 3940 : null;
  @override
  int? get batteryPercent => connected ? 82 : null;
  @override
  DateTime? get radioStartedAt => connected ? _started : null;
  @override
  Future<void> refreshDeviceInfo() async => asked.add('deviceInfo');
  @override
  Future<void> requestCoreStats() async => asked.add('coreStats');
  @override
  Future<void> requestDeviceTime() async => asked.add('deviceTime');
  @override
  Future<void> requestRadioStats() async => asked.add('radioStats');
  @override
  Future<int?> readBleRssi() async => connected ? -64 : null;
  @override
  Future<void> sendFrame(
    Uint8List data, {
    String? channelSendQueueId,
    bool expectsGenericAck = false,
    bool waitForGenericAck = false,
  }) async => sent.add(data.first);
}

bool _barActive(WidgetTester tester) =>
    tester.widget<MeshProgressBar>(find.byType(MeshProgressBar)).active;

VoidCallback? _reloadButton(WidgetTester tester) => tester
    .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.refresh))
    .onPressed;

LastRadio _lastRadio() => LastRadio(
  publicKeyHex: pubKeyToHex(_key),
  name: 'Harbour Node',
  transport: LastRadio.transportBle,
  bleRemoteId: 'D4:3A:2C:91:7E:05',
  savedAt: DateTime.now().subtract(const Duration(days: 1, hours: 1)),
);

Widget _app(MeshCoreConnector connector, Widget home) {
  final storage = StorageService();
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<MeshCoreConnector>.value(value: connector),
      ChangeNotifierProvider(create: (_) => AppSettingsService()),
      ChangeNotifierProvider(create: (_) => PathHistoryService(storage)),
      ChangeNotifierProvider(create: (_) => BleDebugLogService()),
      ChangeNotifierProvider(create: (_) => AppDebugLogService()),
      ChangeNotifierProvider(create: (_) => UiViewStateService()),
      Provider.value(value: storage),
    ],
    child: MaterialApp(
      theme: MeshTheme.light(),
      locale: const Locale('en'),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    ),
  );
}

/// The connected status dot pulses forever, so pump for a fixed time
/// instead of waiting for the screen to settle.
Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Lets the review radio answer: its replies use real and fake timers.
Future<void> _until(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
}

Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await _frames(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  WidgetController.hitTestWarningShouldBeFatal = true;

  final tempDir = Directory.systemTemp.createTempSync('device_info_test');
  String? copied;

  setUpAll(() async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tempDir.path,
    );
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map<dynamic, dynamic>)['text'] as String?;
      }
      return null;
    });
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
  });

  setUp(() {
    copied = null;
  });

  testWidgets('connected review radio shows its values and the extra replies', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final storage = StorageService();
    final settings = AppSettingsService();
    final connector = MeshCoreConnector();
    await tester.runAsync(() async {
      await settings.loadSettings();
      connector.initialize(
        retryService: MessageRetryService(),
        pathHistoryService: PathHistoryService(storage),
        appSettingsService: settings,
        translationService: TranslationService(settings),
      );
      connector.reviewRadioFactoryForTest = () => ReviewRadio(
        scheduledMessageInterval: const Duration(hours: 1),
        ackDelay: const Duration(milliseconds: 50),
        replyDelay: const Duration(hours: 1),
      );
      await connector.connectReview();
      final end = DateTime.now().add(const Duration(seconds: 8));
      while (connector.selfName == null && DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    });

    await tester.pumpWidget(_app(connector, const DeviceInfoScreen()));
    await _until(
      tester,
      () =>
          connector.radioStartedAt != null &&
          connector.radioClockOffset != null &&
          connector.latestRadioStats != null,
    );
    await _frames(tester);

    expect(find.text(connector.selfName!), findsOneWidget);
    expect(find.text(_l10n.common_connected), findsWidgets);
    // Review mode has no link to name.
    expect(find.text(_l10n.connectionChoiceBluetoothLabel), findsNothing);
    expect(find.text(connector.selfPublicKeyHex), findsOneWidget);
    expect(find.text('MeshCore Open Review'), findsOneWidget);
    expect(find.text(_l10n.repeater_uptime.toUpperCase()), findsOneWidget);

    await _scrollTo(tester, find.text(_l10n.deviceInfo_frequency));
    expect(
      find.text(
        _l10n.losFrequencyValue(
          (ReviewScript.frequencyHz / 1000).toStringAsFixed(3),
        ),
      ),
      findsOneWidget,
    );
    expect(find.text('62.5 kHz'), findsOneWidget);
    await _scrollTo(tester, find.text(_l10n.deviceInfo_transmit));
    expect(find.text('12s'), findsOneWidget);
    expect(find.text('48s'), findsOneWidget);
    await _scrollTo(tester, find.text(_l10n.deviceInfo_viewAsText));
    expect(find.text(_l10n.contact_telemetry), findsWidgets);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('PIN stays hidden until tapped and never reaches the text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _app(_FakeRadio(pin: _pin), const DeviceInfoScreen()),
    );
    await _frames(tester);

    expect(find.text('Harbour Node'), findsOneWidget);
    expect(find.text('82% 3.94V'), findsOneWidget);
    expect(find.text('2h 28m'), findsOneWidget);
    expect(find.text(_l10n.connectionChoiceBluetoothLabel), findsWidgets);
    expect(find.text('2s behind'), findsOneWidget);

    await _scrollTo(tester, find.text(_l10n.deviceInfo_blePin));
    expect(find.text('-64 dBm'), findsOneWidget);
    expect(find.text('D4:3A:2C:91:7E:05'), findsOneWidget);
    expect(find.text('••••••'), findsOneWidget);
    expect(find.text('$_pin'), findsNothing);
    expect(find.text(_l10n.deviceInfo_pinFixed), findsOneWidget);

    await tester.tap(find.byTooltip(_l10n.deviceInfo_showPin));
    await _frames(tester);
    expect(find.text('$_pin'), findsOneWidget);
    expect(find.byTooltip(_l10n.deviceInfo_hidePin), findsOneWidget);

    await _scrollTo(tester, find.text(_l10n.deviceInfo_viewAsText));
    await tester.tap(find.text(_l10n.deviceInfo_viewAsText));
    await tester.pumpAndSettle();
    final report = tester
        .widget<SelectableText>(find.byType(SelectableText))
        .data!;
    expect(report, isNot(contains('$_pin')));
    expect(report, contains(_l10n.deviceInfo_reportPinFixed));
    expect(report, contains('-64 dBm'));
    expect(report, contains('Heltec V3'));
    expect(report, contains(pubKeyToHex(_key)));

    await tester.tap(find.text(_l10n.common_copy));
    await tester.pump();
    expect(copied, report);
    expect(find.text(_l10n.deviceInfo_copied), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a PIN that is not fixed says so', (tester) async {
    tester.view.physicalSize = const Size(400, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_app(_FakeRadio(pin: 0), const DeviceInfoScreen()));
    await _frames(tester);
    await _scrollTo(tester, find.text(_l10n.deviceInfo_blePin));
    expect(find.text(_l10n.deviceInfo_pinNotFixed), findsOneWidget);
    expect(find.text(_l10n.deviceInfo_pinNotFixedHint), findsOneWidget);
    expect(find.byTooltip(_l10n.deviceInfo_showPin), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('offline page shows the last radio and hides unknown values', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _app(
        _FakeRadio(connected: false, fakeLastRadio: _lastRadio()),
        const DeviceInfoScreen(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(_l10n.repeater_radioDisconnected), findsOneWidget);
    expect(find.text('Harbour Node'), findsOneWidget);
    expect(
      find.text(_l10n.deviceInfo_lastConnectedAgo(_l10n.time_daysAgo(1))),
      findsOneWidget,
    );
    expect(find.text(_l10n.common_disconnected), findsOneWidget);
    expect(find.text(_l10n.connectionChoiceBluetoothLabel), findsNWidgets(2));
    expect(find.text(pubKeyToHex(_key)), findsOneWidget);
    expect(find.text(_l10n.deviceInfo_lastConnected), findsOneWidget);
    expect(find.text('D4:3A:2C:91:7E:05'), findsOneWidget);
    expect(find.text(_l10n.common_notAvailable), findsOneWidget);
    // Nothing is known about the device itself, and live values stay hidden.
    expect(find.text(_l10n.deviceInfo_device.toUpperCase()), findsNothing);
    expect(find.text(_l10n.deviceInfo_storage.toUpperCase()), findsNothing);
    expect(find.text(_l10n.repeater_uptime.toUpperCase()), findsNothing);
    expect(find.text(_l10n.deviceInfo_blePin), findsNothing);
    expect(find.text(_l10n.deviceInfo_frequency), findsNothing);
    expect(find.text(_l10n.deviceInfo_mesh.toUpperCase()), findsNothing);
    expect(find.text(_l10n.contact_telemetry), findsNothing);
    expect(find.text(_l10n.deviceInfo_viewAsText), findsOneWidget);
    expect(_reloadButton(tester), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Reload asks the radio again for everything on the page', (
    tester,
  ) async {
    final radio = _FakeRadio(pin: _pin);
    await tester.pumpWidget(_app(radio, const DeviceInfoScreen()));
    await _frames(tester);
    expect(radio.asked, isNot(contains('deviceInfo')));
    radio.asked.clear();
    radio.sent.clear();

    await tester.tap(find.byTooltip(_l10n.repeater_refresh));
    await tester.pump();
    expect(_barActive(tester), isTrue);
    expect(_reloadButton(tester), isNull);
    await _frames(tester);

    expect(radio.asked, [
      'deviceInfo',
      'coreStats',
      'deviceTime',
      'radioStats',
    ]);
    expect(radio.sent, [cmdSendTelemetryReq]);
    expect(_reloadButton(tester), isNotNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Tapping the radio clock syncs it and reads it back', (
    tester,
  ) async {
    final radio = _FakeRadio(pin: _pin);
    await tester.pumpWidget(_app(radio, const DeviceInfoScreen()));
    await _frames(tester);
    radio.asked.clear();
    radio.sent.clear();

    await _scrollTo(tester, find.text('2s behind'));
    await tester.tap(find.text('2s behind'));
    await tester.pump();
    expect(_barActive(tester), isTrue);
    await _frames(tester);

    expect(radio.sent, [cmdSetDeviceTime]);
    expect(radio.asked, ['deviceTime']);
    expect(find.text(_l10n.settings_timeSent), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Tapping Uptime asks to confirm, then reboots the radio', (
    tester,
  ) async {
    final radio = _FakeRadio(pin: _pin);
    await tester.pumpWidget(_app(radio, const DeviceInfoScreen()));
    await _frames(tester);
    radio.sent.clear();
    final uptime = find.text(_l10n.repeater_uptime.toUpperCase());

    await tester.tap(uptime);
    await _frames(tester);
    expect(find.text(_l10n.settings_rebootDeviceConfirm), findsOneWidget);
    await tester.tap(find.text(_l10n.common_cancel));
    await _frames(tester);
    expect(radio.sent, isEmpty);

    await tester.tap(uptime);
    await _frames(tester);
    await tester.tap(find.text(_l10n.common_reboot));
    await tester.pump();
    expect(radio.sent, [cmdReboot]);
    await _frames(tester);
    expect(find.text(_l10n.settings_rebootSent), findsOneWidget);
    // Busy until the radio drops off, which this one never does.
    expect(_barActive(tester), isTrue);
    expect(_reloadButton(tester), isNull);
    await tester.pump(const Duration(seconds: 16));
    expect(_reloadButton(tester), isNotNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the key row opens the share page with the info card', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _app(
        _FakeRadio(connected: false, fakeLastRadio: _lastRadio()),
        const DeviceInfoScreen(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(pubKeyToHex(_key)));
    await tester.pumpAndSettle();

    expect(find.byType(ShareContactScreen), findsOneWidget);
    expect(find.text(_l10n.shareContact_title), findsOneWidget);
    expect(find.byType(QrCodeDisplay), findsOneWidget);
    expect(find.text(_l10n.shareContact_scanHint), findsOneWidget);
    final hex = pubKeyToHex(_key);
    final grouped = [
      for (var i = 0; i < hex.length; i += 8) hex.substring(i, i + 8),
    ].join(' ');
    expect(find.text(grouped), findsOneWidget);

    await tester.scrollUntilVisible(
      find.byType(MeshInfoCard),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text(_l10n.shareContact_info), findsOneWidget);

    await tester.tap(find.text(_l10n.shareContact_copyKey));
    await tester.pump();
    expect(copied, hex);
    expect(find.text(_l10n.settings_publicKeyCopied), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Settings row shows the last radio and opens the page', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        _FakeRadio(connected: false, fakeLastRadio: _lastRadio()),
        const SettingsScreen(),
      ),
    );
    await tester.pumpAndSettle();

    final row = find.byType(DeviceInfoSettingsRow);
    expect(row, findsOneWidget);
    for (final text in [
      'Harbour Node',
      _l10n.deviceInfo_lastConnectedAgo(_l10n.time_daysAgo(1)),
      _l10n.common_disconnected,
      _l10n.connectionChoiceBluetoothLabel,
    ]) {
      expect(
        find.descendant(of: row, matching: find.text(text)),
        findsOneWidget,
        reason: text,
      );
    }

    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.byType(DeviceInfoScreen), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
