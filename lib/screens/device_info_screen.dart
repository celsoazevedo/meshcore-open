import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';
import '../helpers/cayenne_lpp.dart';
import '../helpers/snack_bar_builder.dart';
import '../l10n/app_localizations.dart';
import '../l10n/l10n.dart';
import '../models/app_settings.dart';
import '../services/app_settings_service.dart';
import '../storage/last_radio_store.dart';
import '../theme/mesh_theme.dart';
import '../utils/radio_actions.dart';
import '../utils/platform_info.dart';
import '../utils/radio_guard.dart';
import '../utils/route_transitions.dart';
import '../utils/share_origin.dart';
import '../widgets/adaptive_app_bar_title.dart';
import '../widgets/chat_day_separator.dart';
import '../widgets/mesh_nav_tile.dart';
import '../widgets/mesh_ui.dart';
import '../widgets/node_info_sheet.dart';
import '../widgets/radio_disconnected_banner.dart';
import '../widgets/radio_stats_entry.dart';
import '../widgets/sync_progress_overlay.dart';
import 'about_screen.dart';
import 'channels_screen.dart';
import 'contacts_screen.dart';
import 'privacy_settings_screen.dart';
import 'radio_settings_screen.dart';
import 'share_contact_screen.dart';
import 'telemetry_screen.dart';

const String _maskedPin = '••••••';

/// The radio's name: the connected one, else the one last connected.
String _deviceName(MeshCoreConnector c) => c.isConnected
    ? c.deviceDisplayName
    : c.lastRadioName ?? c.deviceDisplayName;

/// Full public key hex of the radio named by [_deviceName], if known.
String? _deviceKey(MeshCoreConnector c) {
  if (c.isConnected) return c.selfPublicKey == null ? null : c.selfPublicKeyHex;
  final key = c.lastRadio?.publicKeyHex;
  return key == null || key.isEmpty ? null : key;
}

/// Icon and name of the current link, or of the last one while offline.
/// Null in review mode or when unknown.
(IconData, String)? _link(AppLocalizations l10n, MeshCoreConnector c) {
  final transport = c.isConnected
      ? c.activeTransport
      : switch (c.lastRadio?.transport) {
          LastRadio.transportBle => MeshCoreTransportType.bluetooth,
          LastRadio.transportUsb => MeshCoreTransportType.usb,
          LastRadio.transportTcp => MeshCoreTransportType.tcp,
          _ => null,
        };
  return switch (transport) {
    MeshCoreTransportType.bluetooth => (
      Icons.bluetooth,
      l10n.connectionChoiceBluetoothLabel,
    ),
    MeshCoreTransportType.usb => (Icons.usb, l10n.connectionChoiceUsbLabel),
    MeshCoreTransportType.tcp => (Icons.lan, l10n.connectionChoiceTcpLabel),
    _ => null,
  };
}

/// Bluetooth address, USB port or TCP endpoint of the link in [_link].
/// On iOS and macOS the Bluetooth address is an ID from the system.
String? _linkAddress(MeshCoreConnector c) {
  final radio = c.lastRadio;
  final address = c.isConnected
      ? switch (c.activeTransport) {
          MeshCoreTransportType.bluetooth => c.deviceId,
          MeshCoreTransportType.usb =>
            c.activeUsbPortDisplayLabel ?? c.activeUsbPort,
          MeshCoreTransportType.tcp => c.activeTcpEndpoint,
          MeshCoreTransportType.review => null,
        }
      : radio == null
      ? null
      : radio.canReconnectTcp
      ? '${radio.tcpHost}:${radio.tcpPort}'
      : radio.transport == LastRadio.transportBle
      ? radio.bleRemoteId
      : null;
  return address == null || address.isEmpty ? null : address;
}

bool _isBluetoothLink(MeshCoreConnector c) =>
    c.isConnected && c.activeTransport == MeshCoreTransportType.bluetooth;

String _lastConnectedText(AppLocalizations l10n, DateTime savedAt) {
  return DateTime.now().difference(savedAt).inSeconds < 60
      ? l10n.deviceInfo_lastConnectedJustNow
      : l10n.deviceInfo_lastConnectedAgo(formatNodeLastSeen(l10n, savedAt));
}

/// "3d 4h", "2h 28m", "5m 12s" or "42s".
String _compactDuration(AppLocalizations l10n, Duration duration) {
  final d = duration.isNegative ? Duration.zero : duration;
  if (d.inDays >= 1) {
    return l10n.deviceInfo_durationDays(d.inDays, d.inHours % 24);
  }
  if (d.inHours >= 1) {
    return l10n.deviceInfo_durationHours(d.inHours, d.inMinutes % 60);
  }
  if (d.inMinutes >= 1) {
    return l10n.deviceInfo_durationMinutes(d.inMinutes, d.inSeconds % 60);
  }
  return l10n.deviceInfo_durationSeconds(d.inSeconds);
}

/// "42 sec", "5 min", "2 hours" or "3 days 4 hours".
String _shortDuration(AppLocalizations l10n, Duration duration) {
  final d = duration.isNegative ? Duration.zero : duration;
  if (d.inDays >= 1) return l10n.deviceInfo_forDays(d.inDays, d.inHours % 24);
  if (d.inHours >= 1) return l10n.deviceInfo_forHours(d.inHours);
  if (d.inMinutes >= 1) return l10n.deviceInfo_forMinutes(d.inMinutes);
  return l10n.deviceInfo_forSeconds(d.inSeconds);
}

/// "Yesterday, 14:32".
String _dayTime(BuildContext context, DateTime time) =>
    context.l10n.deviceInfo_dayTime(
      formatChatDayLabel(context, time),
      formatChatTime(context, time),
    );

/// The time alone for today, else [_dayTime].
String _timeOrDayTime(BuildContext context, DateTime time) =>
    isSameChatDay(time, DateTime.now())
    ? formatChatTime(context, time)
    : _dayTime(context, time);

/// [formatChatTime] with seconds.
String _timeWithSeconds(BuildContext context, DateTime time) {
  final locale = Localizations.localeOf(context).toString();
  final format = MediaQuery.alwaysUse24HourFormatOf(context)
      ? DateFormat.Hms(locale)
      : DateFormat.jms(locale);
  return format.format(time);
}

/// "2s behind", "2s ahead" or "In sync", for radio clock minus phone clock.
String _clockText(AppLocalizations l10n, Duration offset) {
  final seconds = (offset.inMilliseconds / 1000).round();
  if (seconds == 0) return l10n.deviceInfo_clockInSync;
  final amount = _compactDuration(l10n, Duration(seconds: seconds.abs()));
  return seconds < 0
      ? l10n.deviceInfo_clockBehind(amount)
      : l10n.deviceInfo_clockAhead(amount);
}

String _onOff(AppLocalizations l10n, bool on) =>
    on ? l10n.deviceInfo_on : l10n.deviceInfo_off;

String _hashSizeText(AppLocalizations l10n, int byteWidth) =>
    switch (byteWidth) {
      2 => l10n.repeater_pathHashModeOption1,
      3 => l10n.repeater_pathHashModeOption2,
      _ => l10n.repeater_pathHashModeOption0,
    };

/// Radio parameters, formatted like Radio Settings shows them.
({String? frequency, String? bandwidth, String? sf, String? cr, String? tx})
_radioTexts(AppLocalizations l10n, MeshCoreConnector c) {
  final freq = c.currentFreqHz;
  final bw = c.currentBwHz;
  final sf = c.currentSf;
  final cr = c.currentCr;
  final tx = c.currentTxPower;
  final khz = bw == null ? null : bw / 1000;
  // Firmware reports the coding rate as 1-4 or 5-8.
  final uiCr = cr == null || cr > 4 ? cr : cr + 4;
  return (
    frequency: freq == null
        ? null
        : l10n.losFrequencyValue((freq / 1000.0).toStringAsFixed(3)),
    bandwidth: khz == null
        ? null
        : l10n.deviceInfo_khz(
            khz == khz.roundToDouble() ? '${khz.toInt()}' : '$khz',
          ),
    sf: sf == null ? null : 'SF$sf',
    cr: uiCr == null ? null : '4/$uiCr',
    tx: tx == null ? null : l10n.deviceInfo_dbm(tx),
  );
}

/// Storage is reported with the battery and never cleared, so it is only
/// trusted while connected.
bool _storageKnown(MeshCoreConnector c) =>
    c.isConnected &&
    (c.storageUsedKb ?? -1) >= 0 &&
    (c.storageTotalKb ?? 0) > 0;

String? _locationText(MeshCoreConnector c) {
  final lat = c.selfLatitude;
  final lon = c.selfLongitude;
  if (lat == null || lon == null || (lat == 0 && lon == 0)) return null;
  return '${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)}';
}

/// The platform the app runs on, for the text report.
String get _platformName => PlatformInfo.isWeb
    ? 'Web'
    : PlatformInfo.isAndroid
    ? 'Android'
    : PlatformInfo.isIOS
    ? 'iOS'
    : PlatformInfo.isMacOS
    ? 'macOS'
    : PlatformInfo.isWindows
    ? 'Windows'
    : 'Linux';

/// Detail columns: two side by side unless the text is large for the width
/// (about 1.5x on a phone, 1.3x on a 320dp one).
bool _useTwoColumns(BuildContext context) =>
    (MediaQuery.sizeOf(context).width - 32) /
        MediaQuery.textScalerOf(context).scale(1) >=
    240;

/// The Device Info row in Settings. Opens [DeviceInfoScreen].
class DeviceInfoSettingsRow extends StatelessWidget {
  final MeshCoreConnector connector;

  const DeviceInfoSettingsRow({super.key, required this.connector});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MergeSemantics(
      child: Semantics(
        button: true,
        child: InkWell(
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute<void>(builder: (_) => const DeviceInfoScreen()),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Row(
              children: [
                Expanded(child: _DeviceSummary(connector)),
                const SizedBox(width: 8),
                Icon(
                  Icons.chevron_right,
                  size: 24,
                  color: scheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Name, when it was last connected (offline), and the status and link
/// chips. Shared by the Settings row and the page header.
class _DeviceSummary extends StatelessWidget {
  final MeshCoreConnector connector;

  const _DeviceSummary(this.connector);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final connected = connector.isConnected;
    final savedAt = connected ? null : connector.lastRadio?.savedAt;
    final link = _link(l10n, connector);
    final chipColor = connected ? scheme.primary : scheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _deviceName(connector),
          style: MeshTheme.mono(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: scheme.onSurface,
          ),
        ),
        if (savedAt != null) ...[
          const SizedBox(height: 2),
          Text(
            _lastConnectedText(l10n, savedAt),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            StatusChip(
              label: connected
                  ? l10n.common_connected
                  : l10n.common_disconnected,
              color: chipColor,
              pulse: connected,
            ),
            if (link != null)
              StatusChip(icon: link.$1, label: link.$2, color: chipColor),
          ],
        ),
      ],
    );
  }
}

/// Everything known about the companion radio, offline too.
class DeviceInfoScreen extends StatefulWidget {
  const DeviceInfoScreen({super.key});

  @override
  State<DeviceInfoScreen> createState() => _DeviceInfoScreenState();
}

class _DeviceInfoScreenState extends State<DeviceInfoScreen> {
  late final MeshCoreConnector _connector;
  StreamSubscription<Uint8List>? _frames;
  Timer? _tick;

  /// [MeshCoreConnector.connectedAt] of the link the requests went out on.
  DateTime? _askedFor;
  int? _rssi;
  List<Map<String, dynamic>>? _telemetry;
  bool _showPin = false;
  String? _appVersion;
  bool _reloading = false;
  bool _syncingTime = false;
  bool _rebooting = false;

  @override
  void initState() {
    super.initState();
    _connector = context.read<MeshCoreConnector>();
    _frames = _connector.receivedFrames.listen(_onFrame);
    _connector.addListener(_askOnConnect);
    // Re-reads the signal and moves the durations on.
    _tick = Timer.periodic(const Duration(seconds: 10), (_) => _readRssi());
    _askOnConnect();
    unawaited(_loadAppVersion());
  }

  @override
  void dispose() {
    _connector.removeListener(_askOnConnect);
    _frames?.cancel();
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _loadAppVersion() async {
    try {
      final version = await loadAppVersionLabel();
      if (mounted) setState(() => _appVersion = version);
    } catch (_) {}
  }

  /// Asks the radio for the values only this page shows, once per link,
  /// as soon as the radio has identified itself.
  void _askOnConnect() {
    final c = _connector;
    final link = c.connectedAt;
    if (!c.isConnected || c.selfPublicKey == null || link == null) return;
    if (link == _askedFor) return;
    _askedFor = link;
    _rssi = null;
    _telemetry = null;
    unawaited(_ask());
  }

  Future<void> _ask() async {
    final c = _connector;
    await c.requestCoreStats();
    await c.requestDeviceTime();
    await c.requestRadioStats();
    try {
      await c.sendFrame(buildSendTelemetryReq(null));
    } catch (_) {}
    await _readRssi();
  }

  Future<void> _readRssi() async {
    final rssi = await _connector.readBleRssi();
    if (mounted) setState(() => _rssi = rssi);
  }

  /// Asks the radio again for everything on the page.
  Future<void> _reload() async {
    setState(() => _reloading = true);
    try {
      await _connector.refreshDeviceInfo();
      await _ask();
    } catch (_) {
      // A link that drops mid-way shows as offline.
    } finally {
      // However fast the sends, let a frame draw the bar first.
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) setState(() => _reloading = false);
    }
  }

  Future<void> _syncTime() async {
    if (_syncingTime || !ensureRadioConnected(context)) return;
    setState(() => _syncingTime = true);
    await syncRadioTime(context, _connector);
    // Reads the radio clock back, so the page shows the result.
    await _connector.requestDeviceTime();
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) setState(() => _syncingTime = false);
  }

  Future<void> _reboot() async {
    if (_rebooting) return;
    if (!await confirmRadioReboot(context, _connector) || !mounted) return;
    // No reply comes; busy until the radio drops off, at most 15 s.
    setState(() => _rebooting = true);
    await waitForConnector(
      _connector,
      () => !_connector.isConnected,
      timeout: const Duration(seconds: 15),
    );
    if (mounted) setState(() => _rebooting = false);
  }

  /// Self telemetry: [code][reserved][key prefix x6][Cayenne LPP...].
  void _onFrame(Uint8List frame) {
    if (frame.length < 8 || frame[0] != pushCodeTelemetryResponse) return;
    final key = _connector.selfPublicKey;
    if (key == null || key.length < 6) return;
    if (!listEquals(key.sublist(0, 6), frame.sublist(2, 8))) return;
    final parsed = CayenneLpp.parseByChannel(frame.sublist(8));
    if (mounted) setState(() => _telemetry = parsed);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final c = context.watch<MeshCoreConnector>();
    final imperial = context.select<AppSettingsService, bool>(
      (s) => s.settings.unitSystem == UnitSystem.imperial,
    );
    final two = _useTwoColumns(context);
    final connected = c.isConnected;
    final stats = connected && c.supportsCompanionRadioStats
        ? c.latestRadioStats
        : null;
    final busy = _reloading || _syncingTime || _rebooting;
    return Scaffold(
      appBar: AppBar(
        title: AdaptiveAppBarTitle(l10n.settings_deviceInfo),
        centerTitle: true,
        bottom: SyncProgressAppBarBottom(busy: busy),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: l10n.repeater_refresh,
            onPressed: connected && !busy ? _reload : null,
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            const RadioDisconnectedBanner(),
            const SizedBox(height: 8),
            _header(c),
            SectionHeader(l10n.settings_infoStatus),
            _TileGrid(tiles: _statusTiles(context, c), twoColumns: two),
            ..._section(l10n.deviceInfo_device, _deviceCells(context, c), two),
            ..._section(
              l10n.deviceInfo_connection,
              _connectionCells(context, c),
              two,
            ),
            if (connected)
              ..._section(
                l10n.contact_telemetry,
                _telemetryCells(context, imperial),
                two,
                description: l10n.deviceInfo_telemetryDescription,
                tail: MeshNavTile(
                  icon: Icons.thermostat_outlined,
                  title: l10n.contact_telemetry,
                  onTap: () => pushSelfTelemetryScreen(context),
                ),
              ),
            if (connected)
              ..._section(
                l10n.settings_radioSettings,
                _radioCells(l10n, c),
                two,
                tail: MeshNavTile(
                  icon: Icons.radio,
                  title: l10n.settings_radioSettings,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => RadioSettingsScreen(connector: c),
                    ),
                  ),
                ),
              ),
            if (stats != null)
              ..._section(
                l10n.radioStats_sectionAirtime,
                [
                  _Cell(
                    l10n.deviceInfo_transmit,
                    _compactDuration(l10n, Duration(seconds: stats.txAirSecs)),
                  ),
                  _Cell(
                    l10n.deviceInfo_receive,
                    _compactDuration(l10n, Duration(seconds: stats.rxAirSecs)),
                  ),
                ],
                two,
                description: l10n.deviceInfo_airtimeDescription,
                tail: MeshNavTile(
                  icon: Icons.sensors_outlined,
                  title: l10n.radioStats_settingsTile,
                  onTap: () => pushCompanionRadioStatsScreen(context),
                ),
              ),
            if (connected)
              ..._section(
                l10n.settings_privacy,
                [
                  _Cell(l10n.settings_multiAck, _onOff(l10n, c.multiAcks != 0)),
                  if (_locationText(c) case final location?)
                    _Cell(l10n.settings_location, location, wide: true),
                ],
                two,
                tail: MeshNavTile(
                  icon: Icons.visibility_off_outlined,
                  title: l10n.settings_privacy,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => const PrivacySettingsScreen(),
                    ),
                  ),
                ),
              ),
            SectionHeader(l10n.deviceInfo_asText),
            MeshCard(
              padding: EdgeInsets.zero,
              child: MeshNavTile(
                icon: Icons.notes,
                title: l10n.deviceInfo_viewAsText,
                subtitle: l10n.deviceInfo_viewAsTextSubtitle,
                onTap: () {
                  final now = DateTime.now();
                  Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => _DeviceInfoTextScreen(
                        report: _report(context, now),
                        generatedAt: now,
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(MeshCoreConnector c) {
    final key = _deviceKey(c);
    return MeshCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: _DeviceSummary(c),
          ),
          if (key != null) ...[
            const Divider(height: 1),
            _KeyRow(name: _deviceName(c), publicKeyHex: key),
          ],
        ],
      ),
    );
  }

  List<Widget> _section(
    String label,
    List<_Cell> cells,
    bool twoColumns, {
    String? description,
    Widget? tail,
  }) {
    if (cells.isEmpty && tail == null) return const [];
    return [
      SectionHeader(label, description: description),
      _DetailCard(cells: cells, twoColumns: twoColumns, tail: tail),
    ];
  }

  /// Switches to a main tab, as the bottom bar does.
  void _openTab(Widget screen) => Navigator.of(
    context,
  ).pushAndRemoveUntil(buildQuickSwitchRoute<void>(screen), (_) => false);

  List<Widget> _statusTiles(BuildContext context, MeshCoreConnector c) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final grouped = NumberFormat.decimalPattern(
      Localizations.localeOf(context).toString(),
    );
    final connected = c.isConnected;
    final percent = connected ? c.batteryPercent : null;
    final millivolts = connected ? c.batteryMillivolts : null;
    final low = percent != null && percent <= 15;
    final now = DateTime.now();
    final startedAt = connected ? c.radioStartedAt : null;
    final connectedAt = connected ? c.connectedAt : null;
    return [
      StatTile(
        icon: percent == null
            ? Icons.battery_unknown
            : low
            ? Icons.battery_alert
            : Icons.battery_full,
        color: low ? scheme.tertiary : null,
        label: l10n.settings_infoBattery,
        onTap: connected ? () => pushSelfTelemetryScreen(context) : null,
        hint: l10n.contact_telemetry,
        value: percent == null
            ? l10n.common_notAvailable
            : l10n.common_percentValue(percent),
        unit: percent == null || millivolts == null
            ? null
            : l10n.deviceInfo_volts((millivolts / 1000).toStringAsFixed(2)),
      ),
      if (_storageKnown(c))
        StatTile(
          icon: Icons.sd_storage,
          label: l10n.deviceInfo_storage,
          value: grouped.format(c.storageUsedKb!),
          unit: l10n.deviceInfo_storageOf(grouped.format(c.storageTotalKb!)),
        ),
      StatTile(
        icon: Icons.group,
        label: l10n.contacts_title,
        value: grouped.format(c.contacts.length),
        unit: connected
            ? l10n.deviceInfo_ofMax(grouped.format(c.maxContacts))
            : null,
        onTap: () => _openTab(const ContactsScreen(hideBackButton: true)),
      ),
      StatTile(
        icon: Icons.forum,
        label: l10n.channels_title,
        value: grouped.format(c.channels.length),
        unit: connected
            ? l10n.deviceInfo_ofMax(grouped.format(c.maxChannels))
            : null,
        onTap: () => _openTab(const ChannelsScreen(hideBackButton: true)),
      ),
      if (startedAt != null)
        StatTile(
          icon: Icons.restart_alt,
          label: l10n.repeater_uptime,
          value: _compactDuration(l10n, now.difference(startedAt)),
          onTap: _reboot,
          hint: l10n.settings_rebootDevice,
        ),
      if (connectedAt != null)
        StatTile(
          icon: Icons.timer,
          label: l10n.common_connected,
          value: _compactDuration(l10n, now.difference(connectedAt)),
        ),
    ];
  }

  List<_Cell> _deviceCells(BuildContext context, MeshCoreConnector c) {
    final l10n = context.l10n;
    final startedAt = c.isConnected ? c.radioStartedAt : null;
    final offset = c.isConnected ? c.radioClockOffset : null;
    return [
      if (c.manufacturerName case final model?)
        _Cell(l10n.deviceInfo_model, model, wide: true),
      if (c.firmwareVersionString case final firmware?)
        _Cell(l10n.settings_infoFirmware, firmware),
      if (c.firmwareBuildDate case final buildDate?)
        _Cell(l10n.deviceInfo_buildDate, buildDate),
      if (startedAt != null)
        _Cell(
          l10n.deviceInfo_runningSince,
          _dayTime(context, startedAt),
          sub: l10n.deviceInfo_bootTime,
        ),
      if (offset != null)
        _Cell(
          l10n.deviceInfo_radioClock,
          _clockText(l10n, offset),
          sub: _timeWithSeconds(context, DateTime.now().add(offset)),
          onTap: _syncTime,
          hint: l10n.settings_syncTime,
        ),
    ];
  }

  List<_Cell> _connectionCells(BuildContext context, MeshCoreConnector c) {
    final l10n = context.l10n;
    final link = _link(l10n, c);
    final connectedAt = c.isConnected ? c.connectedAt : null;
    final savedAt = c.isConnected ? null : c.lastRadio?.savedAt;
    final bluetooth = _isBluetoothLink(c);
    final rssi = bluetooth ? _rssi : null;
    final pin = bluetooth ? c.blePin : null;
    return [
      if (link != null)
        _Cell(
          l10n.deviceInfo_link,
          link.$2,
          sub: _linkAddress(c),
          monoSub: true,
        ),
      if (connectedAt != null)
        _Cell(
          l10n.deviceInfo_connectedSince,
          _timeOrDayTime(context, connectedAt),
          sub: _shortDuration(l10n, DateTime.now().difference(connectedAt)),
        ),
      if (savedAt != null)
        _Cell(l10n.deviceInfo_lastConnected, _dayTime(context, savedAt)),
      if (rssi != null)
        _Cell(
          l10n.deviceInfo_signal,
          l10n.deviceInfo_dbm(rssi),
          sub: l10n.deviceInfo_signalUpdated,
        ),
      if (pin != null && pin > 0)
        _Cell(
          l10n.deviceInfo_blePin,
          _showPin ? '$pin'.padLeft(6, '0') : _maskedPin,
          sub: l10n.deviceInfo_pinFixed,
          trailing: IconButton(
            tooltip: _showPin
                ? l10n.deviceInfo_hidePin
                : l10n.deviceInfo_showPin,
            icon: Icon(_showPin ? Icons.visibility_off : Icons.visibility),
            onPressed: () => setState(() => _showPin = !_showPin),
          ),
        )
      else if (pin == 0)
        _Cell(
          l10n.deviceInfo_blePin,
          l10n.deviceInfo_pinNotFixed,
          sub: l10n.deviceInfo_pinNotFixedHint,
        ),
    ];
  }

  List<_Cell> _radioCells(AppLocalizations l10n, MeshCoreConnector c) {
    final radio = _radioTexts(l10n, c);
    final repeat = c.clientRepeat;
    return [
      if (radio.frequency case final frequency?)
        _Cell(l10n.deviceInfo_frequency, frequency, wide: true),
      if (radio.bandwidth case final bandwidth?)
        _Cell(l10n.settings_bandwidth, bandwidth),
      if (radio.sf case final sf?) _Cell(l10n.settings_spreadingFactor, sf),
      if (radio.cr case final cr?) _Cell(l10n.settings_codingRate, cr),
      if (radio.tx case final tx?) _Cell(l10n.deviceInfo_txPower, tx),
      _Cell(l10n.deviceInfo_hashSize, _hashSizeText(l10n, c.pathHashByteWidth)),
      if (repeat != null) _Cell(l10n.deviceInfo_repeat, _onOff(l10n, repeat)),
    ];
  }

  List<_Cell> _telemetryCells(BuildContext context, bool imperial) {
    final l10n = context.l10n;
    final grouped = NumberFormat.decimalPattern(
      Localizations.localeOf(context).toString(),
    )..maximumFractionDigits = 1;
    return [
      for (final channel in _telemetry ?? const <Map<String, dynamic>>[])
        if (channel['values'] case final Map<String, dynamic> values) ...[
          if (values['temperature'] case final num celsius)
            _Cell(
              channel['channel'] == 1
                  ? l10n.telemetry_mcuTemperatureLabel
                  : l10n.telemetry_temperatureLabel,
              imperial
                  ? '${(celsius * 9 / 5 + 32).toStringAsFixed(1)}°F'
                  : '${celsius.toStringAsFixed(1)}°C',
            ),
          if (values['humidity'] case final num humidity)
            _Cell(
              l10n.telemetry_humidityLabel,
              l10n.common_percentValue(humidity.round()),
            ),
          if (values['pressure'] case final num pressure)
            _Cell(
              l10n.telemetry_pressureLabel,
              l10n.telemetry_pressureValue(grouped.format(pressure)),
            ),
        ],
    ];
  }

  /// The page as plain text in the same sections, plus what else the app
  /// knows about the radio without asking it. Never includes the PIN.
  String _report(BuildContext context, DateTime now) {
    final l10n = context.l10n;
    final c = _connector;
    final imperial =
        context.read<AppSettingsService>().settings.unitSystem ==
        UnitSystem.imperial;
    final grouped = NumberFormat.decimalPattern(
      Localizations.localeOf(context).toString(),
    );
    final connected = c.isConnected;
    final detail = l10n.deviceInfo_valueWithDetail;
    final blocks = <List<(String?, String)>>[[]];
    void line(String label, String value) => blocks.last.add((label, value));
    void text(String value) => blocks.last.add((null, value));
    void heading(String title) => blocks.add([(null, title.toUpperCase())]);
    String date(DateTime time) => l10n.deviceInfo_dayTime(
      DateFormat.yMMMd(Localizations.localeOf(context).toString()).format(time),
      formatChatTime(context, time),
    );

    text(_deviceName(c));
    line(
      l10n.deviceInfo_reportGenerated,
      l10n.deviceInfo_dayTime(
        DateFormat.yMMMd(
          Localizations.localeOf(context).toString(),
        ).format(now),
        _timeWithSeconds(context, now),
      ),
    );
    text(connected ? l10n.common_connected : l10n.common_disconnected);

    heading(l10n.settings_infoStatus);
    final percent = connected ? c.batteryPercent : null;
    final millivolts = connected ? c.batteryMillivolts : null;
    if (percent != null) {
      line(
        l10n.settings_infoBattery,
        millivolts == null
            ? l10n.common_percentValue(percent)
            : detail(
                l10n.common_percentValue(percent),
                l10n.deviceInfo_volts((millivolts / 1000).toStringAsFixed(2)),
              ),
      );
    }
    if (_storageKnown(c)) {
      line(
        l10n.deviceInfo_storage,
        '${grouped.format(c.storageUsedKb!)} '
        '${l10n.deviceInfo_storageOf(grouped.format(c.storageTotalKb!))}',
      );
    }
    final contacts = grouped.format(c.contacts.length);
    final channels = grouped.format(c.channels.length);
    line(
      l10n.contacts_title,
      connected
          ? '$contacts ${l10n.deviceInfo_ofMax(grouped.format(c.maxContacts))}'
          : contacts,
    );
    line(
      l10n.channels_title,
      connected
          ? '$channels ${l10n.deviceInfo_ofMax(grouped.format(c.maxChannels))}'
          : channels,
    );
    final startedAt = connected ? c.radioStartedAt : null;
    final connectedAt = connected ? c.connectedAt : null;
    if (startedAt != null) {
      line(
        l10n.repeater_uptime,
        _compactDuration(l10n, now.difference(startedAt)),
      );
    }
    if (connectedAt != null) {
      line(
        l10n.common_connected,
        _compactDuration(l10n, now.difference(connectedAt)),
      );
    }

    heading(l10n.deviceInfo_device);
    if (c.manufacturerName case final model?) {
      line(l10n.deviceInfo_model, model);
    }
    if (c.firmwareVersionString case final firmware?) {
      line(l10n.settings_infoFirmware, firmware);
    }
    if (c.firmwareBuildDate case final buildDate?) {
      line(l10n.deviceInfo_buildDate, buildDate);
    }
    if (connected && c.firmwareVerCode != null) {
      line(l10n.deviceInfo_protocolVersion, '${c.firmwareVerCode}');
    }
    if (startedAt != null) line(l10n.deviceInfo_runningSince, date(startedAt));
    if ((connected ? c.radioClockOffset : null) case final offset?) {
      line(
        l10n.deviceInfo_radioClock,
        detail(
          _timeWithSeconds(context, now.add(offset)),
          _clockText(l10n, offset),
        ),
      );
    }
    final vars = connected ? c.currentCustomVars : null;
    if (vars != null && vars.isNotEmpty) {
      line(
        l10n.deviceInfo_customVars,
        [for (final e in vars.entries) '${e.key}=${e.value}'].join(', '),
      );
    }

    heading(l10n.deviceInfo_connection);
    final link = _link(l10n, c);
    if (link != null) {
      final address = _linkAddress(c);
      line(
        l10n.deviceInfo_link,
        address == null ? link.$2 : detail(link.$2, address),
      );
    }
    if (connectedAt != null) {
      line(
        l10n.deviceInfo_connectedSince,
        detail(
          date(connectedAt),
          _shortDuration(l10n, now.difference(connectedAt)),
        ),
      );
    } else if ((connected ? null : c.lastRadio?.savedAt) case final saved?) {
      line(l10n.deviceInfo_lastConnected, date(saved));
    }
    if (_isBluetoothLink(c) && _rssi != null) {
      line(l10n.deviceInfo_signal, l10n.deviceInfo_dbm(_rssi!));
    }

    final telemetry = connected
        ? _telemetryCells(context, imperial)
        : const <_Cell>[];
    if (telemetry.isNotEmpty) {
      heading(l10n.contact_telemetry);
      for (final cell in telemetry) {
        line(cell.label, cell.value);
      }
    }

    if (connected) {
      heading(l10n.settings_radioSettings);
      for (final cell in _radioCells(l10n, c)) {
        line(cell.label, cell.value);
      }
      if (c.maxTxPower case final max?) {
        line(l10n.deviceInfo_maxTxPower, l10n.deviceInfo_dbm(max));
      }
      if (c.supportsDefaultFloodScope) {
        line(
          l10n.settings_regionRadioDefault,
          c.defaultFloodScopeName ?? l10n.settings_regionDefaultNone,
        );
      }
    }

    final stats = connected && c.supportsCompanionRadioStats
        ? c.latestRadioStats
        : null;
    if (stats != null) {
      heading(l10n.radioStats_sectionAirtime);
      line(
        l10n.deviceInfo_transmit,
        _compactDuration(l10n, Duration(seconds: stats.txAirSecs)),
      );
      line(
        l10n.deviceInfo_receive,
        _compactDuration(l10n, Duration(seconds: stats.rxAirSecs)),
      );
      line(
        l10n.deviceInfo_noiseFloor,
        l10n.deviceInfo_dbm(stats.noiseFloorDbm),
      );
      line(l10n.deviceInfo_lastRssi, l10n.deviceInfo_dbm(stats.lastRssiDbm));
      line(
        l10n.deviceInfo_lastSnr,
        l10n.deviceInfo_db(stats.lastSnrDb.toStringAsFixed(1)),
      );
    }

    if (connected) {
      heading(l10n.settings_privacy);
      line(l10n.settings_multiAck, _onOff(l10n, c.multiAcks != 0));
      if (_locationText(c) case final location?) {
        line(l10n.settings_location, location);
      }
      line(
        l10n.settings_advertLocation,
        _onOff(l10n, c.advertLocationPolicy != 0),
      );
      String mode(int value) => switch (value) {
        teleModeAllowAll => l10n.settings_allowAll,
        teleModeAllowFlags => l10n.settings_allowByContact,
        _ => l10n.settings_denyAll,
      };
      line(l10n.settings_telemetryBaseMode, mode(c.telemetryModeBase));
      line(l10n.settings_telemetryLocationMode, mode(c.telemetryModeLoc));
      line(l10n.settings_telemetryEnvironmentMode, mode(c.telemetryModeEnv));
    }

    heading(l10n.contacts_title);
    int count(int type) => c.contacts.where((x) => x.type == type).length;
    final types = [
      (advTypeChat, l10n.contactsSettings_autoAddUsersTitle, c.autoAddUsers),
      (
        advTypeRepeater,
        l10n.contactsSettings_autoAddRepeatersTitle,
        c.autoAddRepeaters,
      ),
      (
        advTypeRoom,
        l10n.contactsSettings_autoAddRoomServersTitle,
        c.autoAddRoomServers,
      ),
      (
        advTypeSensor,
        l10n.contactsSettings_autoAddSensorsTitle,
        c.autoAddSensors,
      ),
    ];
    for (final (type, label, _) in types) {
      line(label, grouped.format(count(type)));
    }
    line(
      l10n.discoveredContacts_Title,
      grouped.format(c.discoveredContacts.length),
    );
    if (connected && c.supportsAutoAddConfig) {
      final added = [
        for (final (_, label, on) in types)
          if (on ?? false) label,
      ];
      line(
        l10n.contactsSettings_autoAddTitle,
        added.isEmpty ? l10n.deviceInfo_off : added.join(', '),
      );
      if (c.autoAddOverwriteOldest case final overwrite?) {
        line(
          l10n.contactsSettings_overwriteOldestTitle,
          _onOff(l10n, overwrite),
        );
      }
      if (c.autoAddMaxHops case final hops?) {
        line(
          l10n.contactsSettings_hopLimit,
          l10n.contactsSettings_hopLimitOption(hops),
        );
      }
    }

    blocks.add([]);
    if (_deviceKey(c) case final key?) line(l10n.settings_infoPublicKey, key);
    if (_appVersion case final version?) {
      line(
        l10n.deviceInfo_app,
        detail('${l10n.appTitle} $version', _platformName),
      );
    }

    return blocks
        .where((block) => block.any((l) => l.$1 != null))
        .map((block) {
          final width =
              block.fold<int>(0, (w, l) => math.max(w, l.$1?.length ?? 0)) + 2;
          return block
              .map(
                (l) => l.$1 == null ? l.$2 : '${l.$1!.padRight(width)}${l.$2}',
              )
              .join('\n');
        })
        .join('\n\n');
  }
}

/// The radio's public key. Opens [ShareContactScreen].
class _KeyRow extends StatelessWidget {
  final String name;
  final String publicKeyHex;

  const _KeyRow({required this.name, required this.publicKeyHex});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MergeSemantics(
      child: Semantics(
        button: true,
        hint: context.l10n.shareContact_title,
        child: InkWell(
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => ShareContactScreen(
                name: name,
                publicKeyHex: publicKeyHex,
                type: advTypeChat,
              ),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Row(
              children: [
                Icon(Icons.key, size: 20, color: scheme.onSurfaceVariant),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    publicKeyHex,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: MeshTheme.mono(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: scheme.onSurface,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  Icons.chevron_right,
                  size: 24,
                  color: scheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// [StatTile]s two to a row (one at large text); a last odd tile spans.
class _TileGrid extends StatelessWidget {
  final List<Widget> tiles;
  final bool twoColumns;

  const _TileGrid({required this.tiles, required this.twoColumns});

  @override
  Widget build(BuildContext context) {
    final step = twoColumns ? 2 : 1;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < tiles.length; i += step) ...[
            if (i > 0) const SizedBox(height: 8),
            if (step == 1 || i + 1 == tiles.length)
              tiles[i]
            else
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: tiles[i]),
                    const SizedBox(width: 8),
                    Expanded(child: tiles[i + 1]),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// A label over a value in a [_DetailCard].
class _Cell {
  final String label;
  final String value;
  final String? sub;
  final bool monoSub;
  final bool wide;
  final Widget? trailing;

  /// Runs an action; a chevron ends the cell and [hint] names the action.
  final VoidCallback? onTap;
  final String? hint;

  const _Cell(
    this.label,
    this.value, {
    this.sub,
    this.monoSub = false,
    this.wide = false,
    this.trailing,
    this.onTap,
    this.hint,
  });
}

/// [_Cell]s two to a row with lines between rows. A wide cell, or a cell
/// left alone on its row, spans both columns. [tail] goes under a line.
class _DetailCard extends StatelessWidget {
  final List<_Cell> cells;
  final bool twoColumns;
  final Widget? tail;

  const _DetailCard({required this.cells, required this.twoColumns, this.tail});

  @override
  Widget build(BuildContext context) {
    final rows = <List<_Cell>>[];
    _Cell? waiting;
    for (final cell in cells) {
      if (!twoColumns || cell.wide) {
        if (waiting != null) rows.add([waiting]);
        waiting = null;
        rows.add([cell]);
      } else if (waiting == null) {
        waiting = cell;
      } else {
        rows.add([waiting, cell]);
        waiting = null;
      }
    }
    if (waiting != null) rows.add([waiting]);
    return MeshCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, row) in rows.indexed) ...[
            if (i > 0) const Divider(height: 1),
            if (row.length == 1)
              _CellView(row.first)
            else
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: _CellView(row[0])),
                  Expanded(child: _CellView(row[1])),
                ],
              ),
          ],
          if (tail != null) ...[
            if (rows.isNotEmpty) const Divider(height: 1),
            tail!,
          ],
        ],
      ),
    );
  }
}

class _CellView extends StatelessWidget {
  final _Cell cell;

  const _CellView(this.cell);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final secondary = scheme.onSurfaceVariant;
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          cell.label,
          style: theme.textTheme.bodyMedium?.copyWith(color: secondary),
        ),
        const SizedBox(height: 2),
        Text(
          cell.value,
          style: MeshTheme.mono(
            fontSize: 15,
            fontWeight: FontWeight.w500,
            color: scheme.onSurface,
          ),
        ),
        if (cell.sub case final sub?) ...[
          const SizedBox(height: 2),
          Text(
            sub,
            style: cell.monoSub
                ? MeshTheme.mono(fontSize: 12, color: secondary)
                : theme.textTheme.bodySmall?.copyWith(color: secondary),
          ),
        ],
      ],
    );
    final trailing =
        cell.trailing ??
        (cell.onTap == null
            ? null
            : Icon(Icons.chevron_right, size: 20, color: secondary));
    final content = Padding(
      padding: EdgeInsets.fromLTRB(16, 10, cell.trailing == null ? 16 : 4, 10),
      child: trailing == null
          ? text
          : Row(
              children: [
                Expanded(child: text),
                trailing,
              ],
            ),
    );
    if (cell.onTap == null) return content;
    return MergeSemantics(
      child: Semantics(
        button: true,
        hint: cell.hint,
        child: InkWell(onTap: cell.onTap, child: content),
      ),
    );
  }
}

/// [DeviceInfoScreen] as plain text, made once when opened, to copy or
/// save as a .txt file.
class _DeviceInfoTextScreen extends StatelessWidget {
  final String report;
  final DateTime generatedAt;

  const _DeviceInfoTextScreen({
    required this.report,
    required this.generatedAt,
  });

  static const _textFileType = XTypeGroup(label: 'TXT', extensions: ['txt']);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: AdaptiveAppBarTitle(l10n.deviceInfo_asText),
        centerTitle: true,
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(0, 8, 0, 24),
          children: [
            MeshCard(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: SelectableText(
                report,
                style: MeshTheme.mono(fontSize: 13, color: scheme.onSurface),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => _copy(context),
                    icon: const Icon(Icons.content_copy, size: 18),
                    label: Text(l10n.common_copy),
                  ),
                  Builder(
                    builder: (buttonContext) => FilledButton.icon(
                      onPressed: () => _save(buttonContext),
                      icon: const Icon(Icons.save_alt, size: 18),
                      label: Text(l10n.common_save),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: report));
    if (!context.mounted) return;
    showDismissibleSnackBar(
      context,
      content: Text(context.l10n.deviceInfo_copied),
    );
  }

  /// A download on web, a save dialog on desktop, the share sheet on phones
  /// (which have no save dialog), like the other exports.
  Future<void> _save(BuildContext buttonContext) async {
    final l10n = buttonContext.l10n;
    final name =
        'meshcore-open-device-info_'
        '${DateFormat('yyyy-MM-dd_HHmmss', 'en').format(generatedAt)}.txt';
    final file = XFile.fromData(
      Uint8List.fromList(utf8.encode(report)),
      name: name,
      mimeType: 'text/plain',
    );
    try {
      if (PlatformInfo.isWeb) {
        await file.saveTo(name);
      } else if (PlatformInfo.isDesktop) {
        final location = await getSaveLocation(
          suggestedName: name,
          acceptedTypeGroups: const [_textFileType],
        );
        if (location == null) return;
        await file.saveTo(location.path);
      } else {
        final result = await SharePlus.instance.share(
          ShareParams(
            subject: l10n.settings_deviceInfo,
            files: [file],
            fileNameOverrides: [name],
            sharePositionOrigin: shareOriginOf(buttonContext),
          ),
        );
        if (result.status == ShareResultStatus.dismissed) return;
      }
      if (!buttonContext.mounted) return;
      showDismissibleSnackBar(
        buttonContext,
        content: Text(l10n.deviceInfo_saved),
      );
    } catch (e) {
      if (!buttonContext.mounted) return;
      showDismissibleSnackBar(
        buttonContext,
        content: Text('${l10n.settings_gpxExportError} $e'),
      );
    }
  }
}
