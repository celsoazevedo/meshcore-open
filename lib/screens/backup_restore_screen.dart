import 'dart:async';
import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../helpers/snack_bar_builder.dart';
import '../l10n/l10n.dart';
import '../models/image_codec_support.dart';
import '../models/translation_support.dart';
import '../services/app_settings_service.dart';
import '../services/backup_service.dart';
import '../services/image_codec_service.dart';
import '../services/translation_service.dart';
import '../services/ui_view_state_service.dart';
import '../services/message_filter/message_filter_service.dart';
import '../utils/platform_info.dart';
import '../widgets/adaptive_app_bar_title.dart';
import '../widgets/backup_item_list.dart';
import '../widgets/confirm_clear_dialog.dart';
import '../widgets/mesh_nav_tile.dart';
import '../widgets/mesh_ui.dart';
import '../widgets/model_download_list.dart';
import '../widgets/radio_disconnected_banner.dart';
import '../widgets/settings_reveal.dart';
import '../widgets/sync_progress_overlay.dart';

/// Restores the chosen items from a backup file.
class BackupRestoreScreen extends StatefulWidget {
  const BackupRestoreScreen({super.key});

  @override
  State<BackupRestoreScreen> createState() => _BackupRestoreScreenState();
}

class _BackupRestoreScreenState extends State<BackupRestoreScreen> {
  static const int _maxImportBytes = 100 * 1024 * 1024;
  static const _backupService = BackupService();
  static const Set<BackupItem> _deviceStoredItems = {
    BackupItem.deviceName,
    BackupItem.publicKey,
    BackupItem.radioSettings,
    BackupItem.location,
    BackupItem.contactSettings,
    BackupItem.privacySettings,
    BackupItem.contacts,
    BackupItem.channels,
  };
  static const Set<BackupItem> _defaultUncheckedOnRestore = {
    ...defaultUncheckedBackupItems,
    ..._deviceStoredItems,
  };
  final _passwordController = TextEditingController();
  final Set<BackupItem> _selectedItems = {};
  Set<BackupItem>? _availableItems;
  String? _importContents;
  String? _importFileName;
  Timer? _inspectionTimer;
  int _inspectionGeneration = 0;
  bool _hasInitializedImportSelection = false;
  // Shows the password field once the file can't be read as is, until
  // another file is chosen.
  bool _needsPassword = false;
  // Set while a typed password waits to be checked, so Restore can't use it
  // before then.
  bool _checkingPassword = false;
  bool _busy = false;
  // Only the restore step moves the bar, not the model download prompt.
  bool _waitingForRadio = false;

  @override
  void dispose() {
    _inspectionTimer?.cancel();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final items = _availableItems;
    return Scaffold(
      appBar: AppBar(
        title: AdaptiveAppBarTitle(l10n.backupRestore_restoreTitle),
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
              MeshInfoCard(l10n.backupRestore_restoreInfo),
              SectionHeader(l10n.backupRestore_fileHeader),
              MeshCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    MeshNavTile(
                      icon: Icons.file_open_outlined,
                      title: l10n.backupRestore_chooseFile,
                      subtitle:
                          _importFileName ?? l10n.backupRestore_chooseFileHint,
                      onTap: _busy ? null : _selectImportFile,
                    ),
                    RevealOnEnable(
                      visible: _needsPassword,
                      child: Column(
                        children: [
                          const Divider(height: 1, indent: 16),
                          Padding(
                            padding: const EdgeInsets.all(14),
                            child: BackupPasswordField(
                              controller: _passwordController,
                              label: l10n.login_password,
                              enabled: !_busy,
                              checking: _checkingPassword,
                              onChanged: (_) => _scheduleImportInspection(),
                              // Only once a password was tried.
                              helperText:
                                  _passwordController.text.isNotEmpty &&
                                      items?.isEmpty == true
                                  ? l10n.backupRestore_importUnavailable
                                  : null,
                              helperMaxLines: 5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (items != null && items.isNotEmpty)
                BackupItemList(
                  selected: _selectedItems,
                  available: items,
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
      // Pinned, as the item list can be longer than a screen.
      bottomNavigationBar: _importContents == null
          ? null
          : SafeArea(
              top: false,
              minimum: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: FilledButton.icon(
                onPressed:
                    _busy ||
                        _checkingPassword ||
                        _selectedItems.isEmpty ||
                        items == null
                    ? null
                    : _restore,
                icon: _busy
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.restore_page_outlined),
                label: Text(l10n.backupRestore_restore),
              ),
            ),
    );
  }

  Future<void> _selectImportFile() async {
    final l10n = context.l10n;
    try {
      final file = await openFile(acceptedTypeGroups: const [backupFileType]);
      if (file == null) return;
      if (await file.length() > _maxImportBytes) {
        _showMessage(l10n.backupRestore_fileTooLarge);
        return;
      }
      final contents = utf8.decode(await file.readAsBytes());
      if (!mounted) return;
      _inspectionTimer?.cancel();
      _passwordController.clear();
      setState(() {
        _importContents = contents;
        _importFileName = file.name;
        _availableItems = null;
        _selectedItems.clear();
        _hasInitializedImportSelection = false;
        _needsPassword = false;
        _checkingPassword = false;
      });
      await _inspectImport();
    } catch (error) {
      if (mounted) {
        _showMessage(l10n.backupRestore_failed(backupErrorText(error)));
      }
    }
  }

  void _scheduleImportInspection() {
    _inspectionTimer?.cancel();
    setState(() => _checkingPassword = true);
    _inspectionTimer = Timer(const Duration(milliseconds: 350), _inspectImport);
  }

  Future<void> _inspectImport() async {
    final contents = _importContents;
    if (contents == null) return;
    final generation = ++_inspectionGeneration;
    try {
      final info = await _backupService.inspectImport(
        contents: contents,
        password: _passwordController.text,
      );
      if (!mounted || generation != _inspectionGeneration) return;
      setState(() {
        _checkingPassword = false;
        _availableItems = info.availableItems;
        if (info.availableItems.isEmpty) _needsPassword = true;
        if (!_hasInitializedImportSelection) {
          _selectedItems
            ..clear()
            ..addAll(
              info.availableItems.where(
                (item) => !_defaultUncheckedOnRestore.contains(item),
              ),
            );
          _hasInitializedImportSelection = true;
        } else {
          _selectedItems.retainAll(info.availableItems);
        }
      });
    } catch (_) {
      if (!mounted || generation != _inspectionGeneration) return;
      setState(() {
        _checkingPassword = false;
        _availableItems = <BackupItem>{};
        _selectedItems.clear();
        _needsPassword = true;
      });
    }
  }

  Future<void> _restore() async {
    final l10n = context.l10n;
    final connector = context.read<MeshCoreConnector>();
    final appSettingsService = context.read<AppSettingsService>();
    final uiViewStateService = context.read<UiViewStateService>();
    final messageFilterService = context.read<MessageFilterService>();
    final translationService = context.read<TranslationService>();
    final imageCodecService = context.read<ImageCodecService>();
    // One confirmation; the private key gets the identity warning instead.
    final replacesIdentity = _selectedItems.contains(BackupItem.privateKey);
    final confirmed = await showConfirmClearDialog(
      context,
      title: replacesIdentity
          ? l10n.backupRestore_replaceIdentityTitle
          : l10n.backupRestore_confirmRestoreTitle,
      message: replacesIdentity
          ? l10n.backupRestore_replaceIdentityMessage
          : l10n.backupRestore_confirmRestoreMessage,
      confirmLabel: l10n.backupRestore_restore,
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = _waitingForRadio = true);
    try {
      await _backupService.restoreBackup(
        contents: _importContents!,
        password: _passwordController.text,
        items: Set<BackupItem>.of(_selectedItems),
        connector: connector,
        appSettingsService: appSettingsService,
      );
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) setState(() => _waitingForRadio = false);
      if (_selectedItems.any(
        (item) =>
            item == BackupItem.appSettings ||
            item == BackupItem.ipfsKey ||
            item == BackupItem.stadiaMapKey,
      )) {
        await appSettingsService.loadSettings();
        if (_selectedItems.contains(BackupItem.appSettings)) {
          await uiViewStateService.reload();
          await _offerMissingModels(
            appSettingsService,
            translationService,
            imageCodecService,
          );
        }
      }
      if (_selectedItems.contains(BackupItem.channelFilters)) {
        await messageFilterService.load();
      }
      if (mounted) {
        _showMessage(l10n.backupRestore_restoreComplete);
        _passwordController.clear();
        setState(() {
          _importContents = null;
          _importFileName = null;
          _availableItems = null;
          _selectedItems.clear();
          _hasInitializedImportSelection = false;
          _needsPassword = false;
        });
      }
    } catch (error) {
      if (mounted) {
        _showMessage(l10n.backupRestore_failed(backupErrorText(error)));
      }
    } finally {
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) setState(() => _busy = _waitingForRadio = false);
    }
  }

  Future<void> _offerMissingModels(
    AppSettingsService appSettingsService,
    TranslationService translationService,
    ImageCodecService imageCodecService,
  ) async {
    if (PlatformInfo.isWeb) return;
    final settings = appSettingsService.settings;
    final translationId = settings.translationSelectedModelId;
    final imageCodecId = settings.imageCodecSelectedModelId;

    TranslationModelRecord? translationModel;
    for (final model in settings.translationDownloadedModels) {
      if (model.id == translationId) {
        translationModel = model;
        break;
      }
    }
    for (final model in translationPresetModels) {
      if (model.id == translationId) {
        translationModel ??= model;
        break;
      }
    }
    if (translationModel == null &&
        translationId != null &&
        settings.translationModelSourceUrl != null) {
      final uri = Uri.tryParse(settings.translationModelSourceUrl!);
      final pathSegments = uri?.pathSegments ?? const <String>[];
      final fileName = pathSegments.isEmpty ? null : pathSegments.last;
      translationModel = TranslationModelRecord(
        id: translationId,
        name: fileName?.isNotEmpty == true ? fileName! : translationId,
        sourceUrl: settings.translationModelSourceUrl!,
        localPath: '',
        downloadedAt: DateTime.fromMillisecondsSinceEpoch(0),
        fileSizeBytes: 0,
      );
    }

    ImageCodecModelRecord? imageCodecModel;
    for (final model in settings.imageCodecDownloadedModels) {
      if (model.id == imageCodecId) {
        imageCodecModel = model;
        break;
      }
    }
    ImageCodecModelSpec? imageCodecSpec;
    for (final spec in imageCodecPresetModels) {
      if (spec.id == imageCodecId) {
        imageCodecSpec = spec;
        break;
      }
    }
    if (imageCodecModel == null && imageCodecSpec != null) {
      final graph = imageCodecSpec.graph;
      imageCodecModel = ImageCodecModelRecord(
        id: imageCodecSpec.id,
        name: graph.fileName,
        sourceUrl: graph.sourceUrl,
        localPath: '',
        downloadedAt: DateTime.fromMillisecondsSinceEpoch(0),
        fileSizeBytes: imageCodecSpec.totalSizeBytes,
        assetFileNames: [
          for (final asset in imageCodecSpec.assets) asset.fileName,
        ],
        bundleVersion: kImageCodecBundleVersion,
      );
    } else if (imageCodecModel == null &&
        imageCodecId != null &&
        settings.imageCodecModelSourceUrl != null) {
      final uri = Uri.tryParse(settings.imageCodecModelSourceUrl!);
      final pathSegments = uri?.pathSegments ?? const <String>[];
      final fileName = pathSegments.isEmpty ? null : pathSegments.last;
      imageCodecModel = ImageCodecModelRecord(
        id: imageCodecId,
        name: fileName?.isNotEmpty == true ? fileName! : imageCodecId,
        sourceUrl: settings.imageCodecModelSourceUrl!,
        localPath: '',
        downloadedAt: DateTime.fromMillisecondsSinceEpoch(0),
        fileSizeBytes: 0,
      );
    }

    await translationService.refreshDownloadedModels(clearMissing: true);
    await imageCodecService.refreshDownloadedModels(clearMissing: true);

    final translationRequest = translationModel;
    final translationMissing =
        translationRequest != null &&
        !translationService.availableModels.any(
          (model) =>
              model.id == translationRequest.id ||
              model.name == translationRequest.name,
        );
    ImageCodecModelRecord? installedCodec;
    if (imageCodecModel != null) {
      for (final model in imageCodecService.availableModels) {
        if (model.id == imageCodecModel.id ||
            model.name == imageCodecModel.name) {
          installedCodec = model;
          break;
        }
      }
    }
    final codecRequest = imageCodecModel;
    final installedCodecForCheck = installedCodec;
    final imageCodecMissing =
        codecRequest != null &&
        (imageCodecSpec != null
            ? !imageCodecSpec.hasCompleteInstalledRecord(
                imageCodecService.availableModels,
              )
            : installedCodecForCheck == null);
    if (!translationMissing && !imageCodecMissing) return;
    if (!mounted) return;

    await _showModelDownloadDialog(
      translationModel: translationMissing ? translationRequest : null,
      imageCodecModel: imageCodecMissing ? codecRequest : null,
      imageCodecSpec: imageCodecMissing ? imageCodecSpec : null,
      translationService: translationService,
      imageCodecService: imageCodecService,
    );
  }

  Future<void> _showModelDownloadDialog({
    required TranslationModelRecord? translationModel,
    required ImageCodecModelRecord? imageCodecModel,
    required ImageCodecModelSpec? imageCodecSpec,
    required TranslationService translationService,
    required ImageCodecService imageCodecService,
  }) async {
    final l10n = context.l10n;
    var starting = false;
    var cancelRequested = false;
    var translationDone = translationModel == null;
    var imageCodecDone = imageCodecModel == null;
    String? currentModel;
    String? downloadError;
    final servicesListenable = Listenable.merge([
      translationService,
      imageCodecService,
    ]);

    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AnimatedBuilder(
          animation: servicesListenable,
          builder: (context, _) {
            final isDownloading =
                starting ||
                translationService.isDownloading ||
                imageCodecService.isDownloading;
            final translationCurrent = currentModel == translationModel?.name;
            final imageCurrent = currentModel == imageCodecModel?.name;
            final failure = downloadError;

            void requestDownloadCancel() {
              cancelRequested = true;
              translationService.cancelDownload();
              imageCodecService.cancelDownload();
            }

            return PopScope<void>(
              canPop: !isDownloading,
              onPopInvokedWithResult: (didPop, _) {
                if (!didPop && isDownloading) requestDownloadCancel();
              },
              child: AlertDialog(
                title: Text(l10n.backupRestore_missingModelsTitle),
                content: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l10n.backupRestore_missingModelsMessage),
                      const SizedBox(height: 12),
                      ModelDownloadList(
                        rowPadding: const EdgeInsets.symmetric(vertical: 4),
                        items: [
                          if (translationModel != null)
                            _missingModelItem(
                              id: 'translation-${translationModel.id}',
                              name: translationModelFriendlyName(
                                translationModel,
                              ),
                              sizeBytes: translationModel.fileSizeBytes,
                              done: translationDone,
                              current: translationCurrent,
                              downloading:
                                  translationService.isDownloading ||
                                  (starting && translationCurrent),
                              progress: translationService.downloadProgress,
                              downloadedBytes:
                                  translationService.downloadedBytes,
                              totalBytes: translationService.downloadTotalBytes,
                              detail:
                                  translationService.downloadFileName ==
                                      'Merging chunks...'
                                  ? l10n.translation_mergingChunks
                                  : null,
                              error: failure == null
                                  ? null
                                  : l10n.backupRestore_failed(failure),
                            ),
                          if (imageCodecModel != null)
                            _missingModelItem(
                              id: 'image-${imageCodecModel.id}',
                              name:
                                  imageCodecSpec?.label ??
                                  imageCodecModelFriendlyName(imageCodecModel),
                              sizeBytes:
                                  imageCodecSpec?.totalSizeBytes ??
                                  imageCodecModel.fileSizeBytes,
                              done: imageCodecDone,
                              current: imageCurrent,
                              downloading:
                                  imageCodecService.isDownloading ||
                                  (starting && imageCurrent),
                              progress: imageCodecService.downloadProgress,
                              downloadedBytes:
                                  imageCodecService.downloadedBytes,
                              totalBytes: imageCodecService.downloadTotalBytes,
                              detail:
                                  imageCodecService.downloadFileName
                                          ?.startsWith('Verifying ') ==
                                      true
                                  ? l10n.modelDownload_verifying
                                  : null,
                              error: failure == null
                                  ? null
                                  : l10n.backupRestore_failed(failure),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () {
                      if (isDownloading) {
                        requestDownloadCancel();
                      } else {
                        Navigator.pop(dialogContext);
                      }
                    },
                    child: Text(
                      isDownloading
                          ? l10n.backupRestore_cancelDownload
                          : l10n.common_cancel,
                    ),
                  ),
                  FilledButton(
                    onPressed: isDownloading
                        ? null
                        : () async {
                            setDialogState(() {
                              starting = true;
                              currentModel = translationDone
                                  ? imageCodecModel?.name
                                  : translationModel?.name;
                              downloadError = null;
                            });
                            try {
                              if (!translationDone) {
                                final model = translationModel!;
                                if (model.sourceUrl.isEmpty) {
                                  throw StateError(
                                    'No download address is available for ${model.name}',
                                  );
                                }
                                await translationService.downloadModel(
                                  sourceUrl: model.sourceUrl,
                                  fileName: model.name,
                                  id: model.id,
                                );
                                translationDone = true;
                                setDialogState(() {
                                  currentModel = imageCodecModel?.name;
                                });
                              }
                              if (!imageCodecDone) {
                                final model = imageCodecModel!;
                                final spec = imageCodecSpec;
                                if (spec != null) {
                                  await imageCodecService.downloadPresetModel(
                                    spec,
                                  );
                                } else if (model.sourceUrl.isNotEmpty) {
                                  await imageCodecService.downloadModel(
                                    sourceUrl: model.sourceUrl,
                                    fileName: model.name,
                                    id: model.id,
                                  );
                                } else {
                                  throw StateError(
                                    'No download address is available for ${model.name}',
                                  );
                                }
                                imageCodecDone = true;
                              }
                              if (dialogContext.mounted) {
                                Navigator.pop(dialogContext);
                              }
                            } catch (error) {
                              if (dialogContext.mounted) {
                                if (cancelRequested) {
                                  Navigator.pop(dialogContext);
                                } else {
                                  setDialogState(() {
                                    starting = false;
                                    downloadError = backupErrorText(error);
                                  });
                                }
                              }
                            }
                          },
                    child: Text(
                      isDownloading
                          ? l10n.backupRestore_downloading
                          : l10n.backupRestore_downloadModels,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  void _showMessage(String message) {
    if (!mounted) return;
    showDismissibleSnackBar(context, content: Text(message));
  }
}

ModelDownloadItem _missingModelItem({
  required String id,
  required String name,
  required int sizeBytes,
  required bool done,
  required bool current,
  required bool downloading,
  required double? progress,
  required int downloadedBytes,
  required int? totalBytes,
  required String? detail,
  required String? error,
}) {
  final inProgress = downloading && current && !done;
  final failed = error != null && current && !inProgress && !done;
  return ModelDownloadItem(
    id: id,
    name: name,
    sizeBytes: sizeBytes > 0 ? sizeBytes : null,
    status: done
        ? ModelDownloadStatus.ready
        : failed
        ? ModelDownloadStatus.error
        : inProgress
        ? ModelDownloadStatus.downloading
        : ModelDownloadStatus.notDownloaded,
    progress: inProgress ? progress : null,
    downloadedBytes: inProgress ? downloadedBytes : 0,
    totalBytes: inProgress ? totalBytes : null,
    detail: failed
        ? error
        : inProgress
        ? detail
        : null,
  );
}
