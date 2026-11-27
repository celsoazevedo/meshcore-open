import 'dart:async';

import 'package:flutter/material.dart';

import '../connector/meshcore_connector.dart';
import '../helpers/snack_bar_builder.dart';
import '../l10n/l10n.dart';
import '../widgets/confirm_clear_dialog.dart';
import 'radio_guard.dart';

/// Sends the phone's time to the radio, then says so. No reply is awaited.
Future<void> syncRadioTime(
  BuildContext context,
  MeshCoreConnector connector,
) async {
  final l10n = context.l10n;
  try {
    await connector.syncTime();
    if (!context.mounted) return;
    showDismissibleSnackBar(context, content: Text(l10n.settings_timeSent));
  } catch (e) {
    if (!context.mounted) return;
    showDismissibleSnackBar(
      context,
      content: Text(l10n.settings_error(e.toString())),
    );
  }
}

/// Asks to confirm, then reboots the radio. True once the command is sent.
Future<bool> confirmRadioReboot(
  BuildContext context,
  MeshCoreConnector connector,
) async {
  final l10n = context.l10n;
  final confirmed = await showConfirmClearDialog(
    context,
    title: l10n.settings_rebootDevice,
    message: l10n.settings_rebootDeviceConfirm,
    confirmLabel: l10n.common_reboot,
    warning: true,
  );
  if (!confirmed || !context.mounted) return false;
  if (!ensureRadioConnected(context)) return false;
  try {
    await connector.rebootDevice();
  } catch (e) {
    if (context.mounted) {
      showDismissibleSnackBar(
        context,
        content: Text(l10n.settings_error(e.toString())),
      );
    }
    return false;
  }
  if (!context.mounted) return false;
  showDismissibleSnackBar(context, content: Text(l10n.settings_rebootSent));
  return true;
}

/// Completes once [done] is true, checked on each connector change, or
/// after [timeout].
Future<void> waitForConnector(
  MeshCoreConnector connector,
  bool Function() done, {
  Duration? timeout,
}) async {
  final completer = Completer<void>();
  void check() {
    if (done() && !completer.isCompleted) completer.complete();
  }

  connector.addListener(check);
  check();
  try {
    await (timeout == null
        ? completer.future
        : completer.future.timeout(timeout, onTimeout: () {}));
  } finally {
    connector.removeListener(check);
  }
}
