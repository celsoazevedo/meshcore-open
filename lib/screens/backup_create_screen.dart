import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../connector/meshcore_connector.dart';
import '../helpers/snack_bar_builder.dart';
import '../l10n/l10n.dart';
import '../services/app_settings_service.dart';
import '../services/backup_service.dart';
import '../utils/platform_info.dart';
import '../utils/share_origin.dart';
import '../widgets/adaptive_app_bar_title.dart';
import '../widgets/backup_item_list.dart';
import '../widgets/mesh_nav_tile.dart';
import '../widgets/mesh_ui.dart';
import '../widgets/radio_disconnected_banner.dart';
import '../widgets/sync_progress_overlay.dart';

/// Saves the chosen app data and radio settings to a backup file.
class BackupCreateScreen extends StatefulWidget {
  const BackupCreateScreen({super.key});

  @override
  State<BackupCreateScreen> createState() => _BackupCreateScreenState();
}

class _BackupCreateScreenState extends State<BackupCreateScreen> {
  static const _backupService = BackupService();
  final _passwordController = TextEditingController();
  final Set<BackupItem> _selectedItems = BackupItem.values
      .where((item) => !defaultUncheckedBackupItems.contains(item))
      .toSet();
  bool _busy = false;
  // Only the backup step moves the bar, not the save or share dialogs.
  bool _waitingForRadio = false;

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: AdaptiveAppBarTitle(l10n.backupRestore_backup),
        centerTitle: true,
        bottom: SyncProgressAppBarBottom(busy: _waitingForRadio),
      ),
      body: SafeArea(
        top: false,
        child: MeshSettingsTileTheme(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              const RadioDisconnectedBanner(),
              const SizedBox(height: 8),
              MeshInfoCard(l10n.backupRestore_backupWarning),
              // Before the items, as it decides whether keys are saved in
              // plaintext.
              SectionHeader(
                l10n.login_password,
                description: l10n.backupRestore_passwordOptional,
              ),
              MeshCard(
                child: BackupPasswordField(
                  controller: _passwordController,
                  label: l10n.login_password,
                  enabled: !_busy,
                ),
              ),
              BackupItemList(
                selected: _selectedItems,
                enabled: !_busy,
                onChanged: (item, selected) => setState(() {
                  if (selected) {
                    _selectedItems.add(item);
                  } else {
                    _selectedItems.remove(item);
                  }
                }),
              ),
            ],
          ),
        ),
      ),
      // Pinned, as the list is longer than a screen.
      bottomNavigationBar: SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: FilledButton.icon(
          onPressed: _busy || _selectedItems.isEmpty ? null : _createBackup,
          icon: _busy
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.save_outlined),
          label: Text(l10n.backupRestore_backup),
        ),
      ),
    );
  }

  Future<void> _createBackup() async {
    final l10n = context.l10n;
    final connector = context.read<MeshCoreConnector>();
    final shareOrigin = shareOriginOf(context);
    setState(() => _busy = _waitingForRadio = true);
    try {
      final contents = await _backupService.createBackup(
        items: Set<BackupItem>.of(_selectedItems),
        connector: connector,
        settings: context.read<AppSettingsService>().settings,
        password: _passwordController.text,
      );
      // However fast the backup, let a frame draw the bar first.
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      setState(() => _waitingForRadio = false);
      final deviceName = (connector.selfName ?? '')
          .trim()
          .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_')
          .replaceAll(RegExp(r'\s+'), '_')
          .replaceAll(RegExp(r'^\.+'), '')
          .replaceAll(RegExp(r'[. ]+$'), '');
      final filename =
          'meshcore-open_${deviceName.isEmpty ? 'radio' : deviceName}_backup_${DateTime.now().millisecondsSinceEpoch}.json';
      final file = XFile.fromData(
        Uint8List.fromList(utf8.encode(contents)),
        name: filename,
        mimeType: 'application/json',
      );
      if (PlatformInfo.isWeb) {
        await file.saveTo(filename);
      } else if (PlatformInfo.isDesktop) {
        final location = await getSaveLocation(
          suggestedName: filename,
          acceptedTypeGroups: const [backupFileType],
        );
        if (location == null) return;
        await file.saveTo(location.path);
      } else {
        final result = await SharePlus.instance.share(
          ShareParams(
            files: [file],
            fileNameOverrides: [filename],
            sharePositionOrigin: shareOrigin,
          ),
        );
        if (result.status == ShareResultStatus.dismissed) return;
      }
      if (mounted) _showMessage(l10n.backupRestore_backupComplete);
    } catch (error) {
      if (mounted) {
        _showMessage(l10n.backupRestore_failed(backupErrorText(error)));
      }
    } finally {
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) setState(() => _busy = _waitingForRadio = false);
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    showDismissibleSnackBar(context, content: Text(message));
  }
}
