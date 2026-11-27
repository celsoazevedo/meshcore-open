import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../helpers/snack_bar_builder.dart';
import '../l10n/contact_localization.dart';
import '../l10n/l10n.dart';
import '../models/contact.dart';
import '../theme/mesh_theme.dart';
import '../utils/contact_qr.dart';
import '../widgets/adaptive_app_bar_title.dart';
import '../widgets/mesh_ui.dart';
import '../widgets/qr_code_display.dart';

/// A contact's QR code and public key, for adding it on another phone.
class ShareContactScreen extends StatelessWidget {
  final String name;
  final String publicKeyHex;
  final int type;

  const ShareContactScreen({
    super.key,
    required this.name,
    required this.publicKeyHex,
    required this.type,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final secondary = theme.textTheme.bodyMedium?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final link = buildContactQrLink(
      name: name,
      publicKeyHex: publicKeyHex,
      type: type,
    );
    final typeLabel = Contact(
      publicKey: Uint8List(0),
      name: name,
      type: type,
      pathLength: 0,
      path: Uint8List(0),
      lastSeen: DateTime.now(),
    ).typeLabel(l10n);
    final groupedKey = [
      for (var i = 0; i < publicKeyHex.length; i += 8)
        publicKeyHex.substring(i, math.min(i + 8, publicKeyHex.length)),
    ].join(' ');

    return Scaffold(
      appBar: AppBar(
        title: AdaptiveAppBarTitle(l10n.shareContact_title),
        centerTitle: true,
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(0, 8, 0, 24),
          children: [
            MeshCard(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
              child: Column(
                children: [
                  Text(
                    name,
                    textAlign: TextAlign.center,
                    style: MeshTheme.mono(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    typeLabel,
                    textAlign: TextAlign.center,
                    style: secondary,
                  ),
                  LayoutBuilder(
                    builder: (context, constraints) => QrCodeDisplay(
                      data: link,
                      // The code sits in a 16px white frame.
                      size: math.min(200, constraints.maxWidth - 32),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                  Text(
                    l10n.shareContact_scanHint,
                    textAlign: TextAlign.center,
                    style: secondary,
                  ),
                ],
              ),
            ),
            SectionHeader(l10n.settings_infoPublicKey),
            MeshCard(
              child: SelectableText(
                groupedKey,
                textAlign: TextAlign.center,
                style: MeshTheme.mono(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: scheme.onSurface,
                ),
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
                    onPressed: () => _copyKey(context),
                    icon: const Icon(Icons.content_copy, size: 18),
                    label: Text(l10n.shareContact_copyKey),
                  ),
                  Builder(
                    builder: (buttonContext) => FilledButton.icon(
                      onPressed: () => _share(buttonContext, link),
                      icon: const Icon(Icons.share, size: 18),
                      label: Text(l10n.common_share),
                    ),
                  ),
                ],
              ),
            ),
            MeshInfoCard(l10n.shareContact_info),
          ],
        ),
      ),
    );
  }

  Future<void> _copyKey(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: publicKeyHex));
    if (!context.mounted) return;
    showDismissibleSnackBar(
      context,
      content: Text(context.l10n.settings_publicKeyCopied),
    );
  }

  Future<void> _share(BuildContext buttonContext, String link) async {
    final box = buttonContext.findRenderObject() as RenderBox?;
    await SharePlus.instance.share(
      ShareParams(
        text: link,
        subject: name,
        sharePositionOrigin: box == null
            ? null
            : box.localToGlobal(Offset.zero) & box.size,
      ),
    );
  }
}
