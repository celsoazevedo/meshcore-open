import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../services/backup_service.dart';
import 'mesh_ui.dart';

/// Backup file type for the open and save dialogs.
const backupFileType = XTypeGroup(
  label: 'MeshCore backup',
  extensions: ['json'],
  mimeTypes: ['application/json'],
);

/// Sensitive items left unticked by default.
const Set<BackupItem> defaultUncheckedBackupItems = {
  BackupItem.privateKey,
  BackupItem.ipfsKey,
  BackupItem.stadiaMapKey,
};

/// Error text for the failure snackbar, without Dart prefixes such as
/// "Bad state:".
String backupErrorText(Object error) => switch (error) {
  StateError(:final message) => message,
  FormatException(:final message) => message,
  _ => error.toString(),
};

/// Backup password field with a show/hide button, shared by the Create
/// Backup and Restore Backup pages.
class BackupPasswordField extends StatefulWidget {
  final TextEditingController controller;
  final String label;
  final bool enabled;
  final ValueChanged<String>? onChanged;
  final String? helperText;
  final int? helperMaxLines;

  /// Shows the 18px spinner next to the show/hide button while the typed
  /// password is being checked.
  final bool checking;

  const BackupPasswordField({
    super.key,
    required this.controller,
    required this.label,
    this.enabled = true,
    this.onChanged,
    this.helperText,
    this.helperMaxLines,
    this.checking = false,
  });

  @override
  State<BackupPasswordField> createState() => _BackupPasswordFieldState();
}

class _BackupPasswordFieldState extends State<BackupPasswordField> {
  bool _obscured = true;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return TextField(
      controller: widget.controller,
      enabled: widget.enabled,
      obscureText: _obscured,
      autocorrect: false,
      enableSuggestions: false,
      onChanged: widget.onChanged,
      onTapOutside: (_) => FocusScope.of(context).unfocus(),
      decoration: InputDecoration(
        labelText: widget.label,
        helperText: widget.helperText,
        helperMaxLines: widget.helperMaxLines,
        suffixIcon: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.checking)
              const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            IconButton(
              tooltip: _obscured
                  ? l10n.login_showPassword
                  : l10n.login_hidePassword,
              icon: Icon(
                _obscured
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
              ),
              onPressed: widget.enabled
                  ? () => setState(() => _obscured = !_obscured)
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}

/// Backup items as checkbox rows in [SectionHeader] + [MeshCard] groups,
/// shared by the Create Backup and Restore Backup pages.
class BackupItemList extends StatelessWidget {
  final Set<BackupItem> selected;

  /// Items to list. Null lists all; a group with none is left out.
  final Set<BackupItem>? available;
  final bool enabled;
  final void Function(BackupItem item, bool selected) onChanged;

  const BackupItemList({
    super.key,
    required this.selected,
    this.available,
    this.enabled = true,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // Each icon is the one the app already uses for that item.
    final rows = <BackupItem, (IconData, String)>{
      BackupItem.deviceName: (
        Icons.person_outline,
        l10n.backupRestore_deviceName,
      ),
      BackupItem.radioSettings: (Icons.radio, l10n.backupRestore_radioSettings),
      BackupItem.regions: (Icons.landscape, l10n.backupRestore_regions),
      BackupItem.publicKey: (
        Icons.vpn_key_outlined,
        l10n.backupRestore_publicKey,
      ),
      // Outlined form of the private channel lock.
      BackupItem.privateKey: (
        Icons.lock_outline,
        l10n.backupRestore_privateKey,
      ),
      BackupItem.location: (
        Icons.location_on_outlined,
        l10n.backupRestore_location,
      ),
      BackupItem.contactSettings: (
        Icons.group_add_outlined,
        l10n.backupRestore_contactSettings,
      ),
      BackupItem.privacySettings: (
        Icons.visibility_off_outlined,
        l10n.backupRestore_privacySettings,
      ),
      BackupItem.contacts: (
        Icons.people_outline,
        l10n.backupRestore_contactsData,
      ),
      // Discovered Contacts has no row in Settings.
      BackupItem.discoveredContacts: (
        Icons.person_search_outlined,
        l10n.backupRestore_discoveredContacts,
      ),
      BackupItem.contactGroups: (
        Icons.group_outlined,
        l10n.backupRestore_contactGroups,
      ),
      BackupItem.perContactSettings: (
        Icons.settings,
        l10n.backupRestore_perContactSettings,
      ),
      BackupItem.channels: (Icons.tag, l10n.backupRestore_channelsData),
      BackupItem.communities: (
        Icons.groups_outlined,
        l10n.backupRestore_communities,
      ),
      BackupItem.channelSettings: (
        Icons.settings,
        l10n.backupRestore_channelSettings,
      ),
      BackupItem.contactHistory: (
        Icons.chat_bubble_outline,
        l10n.backupRestore_contactHistory,
      ),
      BackupItem.channelHistory: (
        Icons.forum_outlined,
        l10n.backupRestore_channelHistory,
      ),
      BackupItem.bookmarks: (
        Icons.bookmark_border,
        l10n.backupRestore_bookmarks,
      ),
      BackupItem.appSettings: (
        Icons.settings_outlined,
        l10n.backupRestore_appSettings,
      ),
      BackupItem.channelFilters: (
        Icons.filter_alt_outlined,
        l10n.backupRestore_channelFilters,
      ),
      BackupItem.ipfsKey: (Icons.link_outlined, l10n.backupRestore_ipfsKey),
      BackupItem.stadiaMapKey: (
        Icons.key_outlined,
        l10n.backupRestore_stadiaMapKey,
      ),
    };
    // Groups only change how items are shown, not what a backup file holds.
    final groups = <(String, List<BackupItem>)>[
      (
        l10n.settings_nodeSettings,
        const [
          BackupItem.deviceName,
          BackupItem.radioSettings,
          BackupItem.regions,
          BackupItem.publicKey,
          BackupItem.privateKey,
        ],
      ),
      (
        l10n.settings_location,
        const [
          BackupItem.location,
          BackupItem.contactSettings,
          BackupItem.privacySettings,
        ],
      ),
      (
        l10n.backupRestore_contacts,
        const [
          BackupItem.contacts,
          BackupItem.discoveredContacts,
          BackupItem.contactGroups,
          BackupItem.perContactSettings,
        ],
      ),
      (
        l10n.backupRestore_channels,
        const [
          BackupItem.channels,
          BackupItem.communities,
          BackupItem.channelSettings,
        ],
      ),
      (
        l10n.backupRestore_messages,
        const [
          BackupItem.contactHistory,
          BackupItem.channelHistory,
          BackupItem.bookmarks,
        ],
      ),
      (
        l10n.settings_appSettings,
        const [
          BackupItem.appSettings,
          BackupItem.channelFilters,
          BackupItem.ipfsKey,
          BackupItem.stadiaMapKey,
        ],
      ),
    ];

    bool isListed(BackupItem item) =>
        available == null || available!.contains(item);
    Widget checkboxRow({
      required bool? value,
      required IconData icon,
      required String label,
      required ValueChanged<bool?>? onTap,
      bool tristate = false,
    }) => CheckboxListTile(
      value: value,
      tristate: tristate,
      onChanged: onTap,
      secondary: Icon(icon, size: 24),
      title: Text(label),
      controlAffinity: ListTileControlAffinity.trailing,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    );

    final children = <Widget>[];
    final listedItems = [
      for (final (_, items) in groups) ...items.where(isListed),
    ];
    if (listedItems.isNotEmpty) {
      final ticked = listedItems.where(selected.contains).length;
      final allTicked = ticked == listedItems.length;
      // Ticks every listed item, or clears them all once all are ticked.
      children
        ..add(SectionHeader(l10n.backupRestore_itemsHeader))
        ..add(
          MeshCard(
            padding: EdgeInsets.zero,
            child: checkboxRow(
              value: allTicked ? true : (ticked == 0 ? false : null),
              tristate: true,
              icon: Icons.select_all,
              label: l10n.backupRestore_selectAll,
              onTap: enabled
                  ? (_) {
                      for (final item in listedItems) {
                        if (selected.contains(item) == allTicked) {
                          onChanged(item, !allTicked);
                        }
                      }
                    }
                  : null,
            ),
          ),
        );
    }
    for (final (header, items) in groups) {
      final listed = items.where(isListed).toList();
      if (listed.isEmpty) continue;
      children
        ..add(SectionHeader(header))
        ..add(
          MeshCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (final (index, item) in listed.indexed) ...[
                  if (index > 0) const Divider(height: 1, indent: 16),
                  checkboxRow(
                    value: selected.contains(item),
                    icon: rows[item]!.$1,
                    label: rows[item]!.$2,
                    onTap: enabled
                        ? (value) => onChanged(item, value == true)
                        : null,
                  ),
                ],
              ],
            ),
          ),
        );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}
