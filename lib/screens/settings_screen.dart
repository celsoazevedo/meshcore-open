import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../l10n/l10n.dart';
import '../helpers/snack_bar_builder.dart';
import '../widgets/confirm_clear_dialog.dart';
import '../widgets/mesh_nav_tile.dart';
import '../widgets/adaptive_app_bar_title.dart';
import '../widgets/mesh_ui.dart';
import 'about_screen.dart';
import 'app_settings_screen.dart';
import 'contact_settings_screen.dart';
import 'device_info_screen.dart';
import 'location_settings_screen.dart';
import 'node_name_screen.dart';
import 'privacy_settings_screen.dart';
import 'radio_settings_screen.dart';
import 'app_debug_log_screen.dart';
import 'message_filter_settings_screen.dart';
import 'ble_debug_log_screen.dart';
import '../widgets/radio_stats_entry.dart';
import 'telemetry_screen.dart';
import '../widgets/sync_progress_overlay.dart';
import 'region_management_screen.dart';
import 'backup_restore_screen.dart';
import 'export_screen.dart';
import '../utils/radio_actions.dart';
import '../utils/radio_guard.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // Radio actions in progress: the app bar, plus the row spinner while a
  // reply is awaited.
  bool _refreshingContacts = false;
  bool _rebooting = false;
  bool _syncingTime = false;
  void _push(BuildContext context, Widget page) {
    Navigator.push(context, MaterialPageRoute<void>(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(
        // A plain title: AppBarTitle fills the bar and stays left-aligned.
        title: AdaptiveAppBarTitle(l10n.settings_title),
        centerTitle: true,
        bottom: SyncProgressAppBarBottom(busy: _rebooting || _syncingTime),
      ),
      body: SafeArea(
        top: false,
        // Each card selects only the connector fields it renders, so the
        // frequent unrelated connector notifications (frames, contacts,
        // messages) do not rebuild the whole settings list.
        child: ListView(
          padding: const EdgeInsets.fromLTRB(0, 8, 0, 24),
          children: [
            // IDENTITY section
            SectionHeader(l10n.settings_deviceInfo),
            MeshCard(
              padding: EdgeInsets.zero,
              child: _selectConnector(
                (c) => (
                  c.isConnected,
                  c.deviceDisplayName,
                  c.lastRadioName,
                  c.lastRadio?.savedAt,
                  c.lastRadio?.transport,
                  c.activeTransport,
                ),
                (context, connector) =>
                    DeviceInfoSettingsRow(connector: connector),
              ),
            ),

            // NODE section
            SectionHeader(l10n.settings_nodeSettings),
            MeshCard(
              padding: EdgeInsets.zero,
              child: _selectConnector(
                (c) => (
                  c.isConnected,
                  c.selfName,
                  c.supportsCompanionRadioStats,
                  c.firmwareVerCode,
                  c.pathHashByteWidth,
                ),
                _buildNodeCardContent,
              ),
            ),

            // LOCATION section
            SectionHeader(l10n.settings_location),
            MeshCard(
              padding: EdgeInsets.zero,
              child: _selectConnector(
                (c) => c.isConnected,
                _buildLocationCardContent,
              ),
            ),

            // APP SETTINGS
            SectionHeader(l10n.settings_appSettings),
            MeshCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  MeshNavTile(
                    icon: Icons.settings_outlined,
                    title: l10n.settings_appSettings,
                    subtitle: l10n.settings_appSettingsSubtitle,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const AppSettingsScreen(),
                      ),
                    ),
                  ),
                  const Divider(height: 1, indent: 16),
                  MeshNavTile(
                    icon: Icons.filter_alt_outlined,
                    title: l10n.messageFilter_title,
                    subtitle: l10n.messageFilter_settingsSubtitle,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const MessageFilterSettingsScreen(),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // ACTIONS section
            SectionHeader(l10n.settings_actions),
            MeshCard(
              padding: EdgeInsets.zero,
              child: _selectConnector(
                (c) => c.isConnected,
                _buildActionsCardContent,
              ),
            ),

            // BACKUP AND EXPORT
            SectionHeader(l10n.settings_export),
            MeshCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  MeshNavTile(
                    icon: Icons.backup_outlined,
                    title: l10n.backupRestore_title,
                    subtitle: l10n.backupRestore_subtitle,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const BackupRestoreScreen(),
                      ),
                    ),
                  ),
                  const Divider(height: 1, indent: 16),
                  MeshNavTile(
                    icon: Icons.download_outlined,
                    title: l10n.settings_exportData,
                    subtitle: l10n.settings_exportSubtitle,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const ExportScreen()),
                    ),
                  ),
                ],
              ),
            ),

            // DEBUG section
            SectionHeader(l10n.settings_debug),
            MeshCard(
              padding: EdgeInsets.zero,
              child: _buildDebugCardContent(context),
            ),

            // ABOUT
            SectionHeader(l10n.settings_about),
            MeshCard(
              padding: EdgeInsets.zero,
              child: MeshNavTile(
                icon: Icons.info_outline,
                title: l10n.settings_aboutTheApp,
                onTap: () => _push(context, const AboutScreen()),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Rebuilds [builder] only when [selector]'s value changes (records compare
  /// field by field) or when this screen itself rebuilds.
  Widget _selectConnector<T>(
    T Function(MeshCoreConnector connector) selector,
    Widget Function(BuildContext context, MeshCoreConnector connector) builder,
  ) {
    return Selector<MeshCoreConnector, T>(
      selector: (_, connector) => selector(connector),
      builder: (context, _, _) =>
          builder(context, context.read<MeshCoreConnector>()),
    );
  }

  /// Guards a radio command: returns false (after telling the user) when the
  /// radio is not connected, because the connector silently ignores commands
  /// sent while disconnected and a success message would be a lie.
  bool _ensureConnected(BuildContext context, MeshCoreConnector connector) =>
      ensureRadioConnected(context);

  Widget _buildNodeCardContent(
    BuildContext context,
    MeshCoreConnector connector,
  ) {
    final l10n = context.l10n;
    final connected = connector.isConnected;
    final offline = l10n.settings_requiresConnection;
    return Column(
      children: [
        MeshNavTile(
          icon: Icons.person_outline,
          title: l10n.settings_nodeName,
          subtitle: connected
              ? connector.selfName ?? l10n.settings_nodeNameNotSet
              : offline,
          onTap: connected
              ? () => _push(context, const NodeNameScreen())
              : null,
        ),
        const Divider(height: 1, indent: 16),
        MeshNavTile(
          icon: Icons.radio,
          title: l10n.settings_radioSettings,
          subtitle: connected ? l10n.settings_radioSettingsSubtitle : offline,
          onTap: connected
              ? () => _push(context, RadioSettingsScreen(connector: connector))
              : null,
        ),
        const Divider(height: 1, indent: 16),
        MeshNavTile(
          icon: Icons.landscape,
          title: l10n.settings_regionSettings,
          subtitle: l10n.settings_regionSettingsSubtitle,
          onTap: () => pushRegionManagementScreen(context),
        ),
        const Divider(height: 1, indent: 16),
        MeshNavTile(
          icon: Icons.sensors_outlined,
          title: l10n.radioStats_settingsTile,
          subtitle: !connected
              ? offline
              : !connector.supportsCompanionRadioStats
              ? l10n.settings_requiresFirmware('v1.10')
              : l10n.radioStats_settingsSubtitle,
          onTap: connector.isConnected && connector.supportsCompanionRadioStats
              ? () => pushCompanionRadioStatsScreen(context)
              : null,
        ),
        const Divider(height: 1, indent: 16),
        MeshNavTile(
          icon: Icons.thermostat_outlined,
          title: l10n.contact_telemetry,
          subtitle: connected ? l10n.repeater_telemetrySubtitle : offline,
          onTap: connector.isConnected
              ? () => pushSelfTelemetryScreen(context)
              : null,
        ),
      ],
    );
  }

  Widget _buildLocationCardContent(
    BuildContext context,
    MeshCoreConnector connector,
  ) {
    final l10n = context.l10n;
    final connected = connector.isConnected;
    final offline = l10n.settings_requiresConnection;
    return Column(
      children: [
        MeshNavTile(
          icon: Icons.location_on_outlined,
          title: l10n.settings_location,
          subtitle: connected ? l10n.settings_locationSubtitle : offline,
          onTap: connected
              ? () => _push(context, const LocationSettingsScreen())
              : null,
        ),
        const Divider(height: 1, indent: 16),
        MeshNavTile(
          icon: Icons.group_add_outlined,
          title: l10n.settings_contactSettings,
          subtitle: connected ? l10n.settings_contactSettingsSubtitle : offline,
          onTap: connected
              ? () => _push(context, const ContactSettingsScreen())
              : null,
        ),
        const Divider(height: 1, indent: 16),
        MeshNavTile(
          icon: Icons.visibility_off_outlined,
          title: l10n.settings_privacy,
          subtitle: connected ? l10n.settings_privacySubtitle : offline,
          onTap: connected
              ? () => _push(context, const PrivacySettingsScreen())
              : null,
        ),
      ],
    );
  }

  Widget _buildActionsCardContent(
    BuildContext context,
    MeshCoreConnector connector,
  ) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final connected = connector.isConnected;
    final offline = l10n.settings_requiresConnection;
    return Column(
      children: [
        MeshNavTile(
          icon: Icons.sync,
          title: l10n.settings_syncTime,
          subtitle: connected ? l10n.settings_syncTimeSubtitle : offline,
          onTap: connected ? () => _syncTime(context, connector) : null,
        ),
        const Divider(height: 1, indent: 16),
        MeshNavTile(
          icon: Icons.refresh,
          title: l10n.settings_refreshContacts,
          subtitle: connected ? l10n.settings_refreshContactsSubtitle : offline,
          busy: _refreshingContacts && connected,
          onTap: connected ? () => _refreshContacts(context, connector) : null,
        ),
        const Divider(height: 1, indent: 16),
        MeshNavTile(
          icon: Icons.restart_alt,
          title: l10n.settings_rebootDevice,
          subtitle: connected ? l10n.settings_rebootDeviceSubtitle : offline,
          titleColor: scheme.tertiary,
          iconColor: scheme.tertiary,
          busy: _rebooting && connected,
          onTap: connected ? () => _confirmReboot(context, connector) : null,
        ),
        const Divider(height: 1, indent: 16),
        MeshNavTile(
          icon: Icons.delete_outline,
          title: l10n.settings_deleteAllPaths,
          subtitle: l10n.settings_deleteAllPathsSubtitle,
          titleColor: scheme.error,
          iconColor: scheme.error,
          onTap: () => _confirmDeleteAllPaths(context, connector),
        ),
      ],
    );
  }

  Widget _buildDebugCardContent(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      children: [
        MeshNavTile(
          icon: Icons.bluetooth_outlined,
          title: l10n.settings_companionDebugLog,
          subtitle: l10n.settings_companionDebugLogSubtitle,
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => const BleDebugLogScreen(),
              ),
            );
          },
        ),
        const Divider(height: 1, indent: 16),
        MeshNavTile(
          icon: Icons.code_outlined,
          title: l10n.settings_appDebugLog,
          subtitle: l10n.settings_appDebugLogSubtitle,
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => const AppDebugLogScreen(),
              ),
            );
          },
        ),
      ],
    );
  }

  Future<void> _syncTime(
    BuildContext context,
    MeshCoreConnector connector,
  ) async {
    if (!_ensureConnected(context, connector)) return;
    // The top bar shows the time going to the radio; no reply is awaited.
    setState(() => _syncingTime = true);
    await syncRadioTime(context, connector);
    // However fast the send, let a frame draw the bar first.
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) setState(() => _syncingTime = false);
  }

  Future<void> _refreshContacts(
    BuildContext context,
    MeshCoreConnector connector,
  ) async {
    final l10n = context.l10n;
    if (!_ensureConnected(context, connector)) return;
    setState(() => _refreshingContacts = true);
    try {
      await connector.getContacts();
      // END_OF_CONTACTS sets hasLoadedContacts; a stalled sync ends without.
      await waitForConnector(connector, () => !connector.isLoadingContacts);
    } catch (e) {
      if (context.mounted) {
        showDismissibleSnackBar(
          context,
          content: Text(l10n.settings_error(e.toString())),
        );
      }
      return;
    } finally {
      if (mounted) setState(() => _refreshingContacts = false);
    }
    if (!context.mounted || !connector.isConnected) return;
    showDismissibleSnackBar(
      context,
      content: Text(
        connector.hasLoadedContacts
            ? l10n.settings_contactsRefreshed
            : l10n.settings_radioNoReply,
      ),
    );
  }

  Future<void> _confirmDeleteAllPaths(
    BuildContext context,
    MeshCoreConnector connector,
  ) async {
    final l10n = context.l10n;
    final confirmed = await showConfirmClearDialog(
      context,
      title: l10n.settings_deleteAllPaths,
      message: l10n.settings_deleteAllPathsSubtitle,
      confirmLabel: l10n.common_deleteAll,
    );
    if (!confirmed || !context.mounted) return;
    connector.deleteAllPaths();
    showDismissibleSnackBar(
      context,
      content: Text(l10n.settings_allPathsDeleted),
    );
  }

  Future<void> _confirmReboot(
    BuildContext context,
    MeshCoreConnector connector,
  ) async {
    if (!await confirmRadioReboot(context, connector) || !mounted) return;
    // No reply comes; busy until the radio drops off, at most 15 s.
    setState(() => _rebooting = true);
    await waitForConnector(
      connector,
      () => !connector.isConnected,
      timeout: const Duration(seconds: 15),
    );
    if (mounted) setState(() => _rebooting = false);
  }
}
