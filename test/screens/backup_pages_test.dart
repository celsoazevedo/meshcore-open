import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/l10n/app_localizations_en.dart';
import 'package:meshcore_open/screens/backup_create_screen.dart';
import 'package:meshcore_open/screens/backup_restore_screen.dart';
import 'package:meshcore_open/screens/export_screen.dart';
import 'package:meshcore_open/screens/settings_screen.dart';
import 'package:meshcore_open/services/app_debug_log_service.dart';
import 'package:meshcore_open/services/app_settings_service.dart';
import 'package:meshcore_open/services/backup_service.dart';
import 'package:meshcore_open/services/ble_debug_log_service.dart';
import 'package:meshcore_open/services/image_codec_service.dart';
import 'package:meshcore_open/services/map_tile_cache_service.dart';
import 'package:meshcore_open/services/message_filter/message_filter_service.dart';
import 'package:meshcore_open/services/path_history_service.dart';
import 'package:meshcore_open/services/storage_service.dart';
import 'package:meshcore_open/services/translation_service.dart';
import 'package:meshcore_open/services/ui_view_state_service.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:meshcore_open/theme/mesh_theme.dart';
import 'package:meshcore_open/widgets/backup_item_list.dart';
import 'package:meshcore_open/widgets/mesh_nav_tile.dart';
import 'package:meshcore_open/widgets/radio_disconnected_banner.dart';

final _l10n = AppLocalizationsEn();

/// The radio is offline: both pages stay reachable without it.
Widget _app(Widget home) {
  final settings = AppSettingsService();
  final storage = StorageService();
  return MultiProvider(
    providers: [
      ChangeNotifierProvider(create: (_) => MeshCoreConnector()),
      ChangeNotifierProvider.value(value: settings),
      ChangeNotifierProvider(create: (_) => PathHistoryService(storage)),
      ChangeNotifierProvider(create: (_) => BleDebugLogService()),
      ChangeNotifierProvider(create: (_) => AppDebugLogService()),
      ChangeNotifierProvider(create: (_) => UiViewStateService()),
      Provider.value(value: storage),
      ChangeNotifierProvider(
        create: (_) => MapTileCacheService(appSettingsService: settings),
      ),
      // Read when Restore Selected is pressed.
      ChangeNotifierProvider(create: (_) => MessageFilterService()),
      ChangeNotifierProvider(create: (_) => TranslationService(settings)),
      ChangeNotifierProvider(create: (_) => ImageCodecService(settings)),
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

/// Pumps a fixed time, as some screens animate forever.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Lets real file reads run, and moves the clock for the short pauses in
/// key derivation, until [done].
Future<void> _waitFor(WidgetTester tester, bool Function() done) async {
  final end = DateTime.now().add(const Duration(seconds: 20));
  while (!done() && DateTime.now().isBefore(end)) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump(const Duration(seconds: 1));
  }
  await tester.pump();
}

/// A phone-sized window, or a tall one so every row of a list is built.
void _setView(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// The item rows, without the Select All row.
Finder get _rows =>
    find.byWidgetPredicate((w) => w is CheckboxListTile && !w.tristate);

Finder get _selectAll =>
    find.widgetWithText(CheckboxListTile, _l10n.backupRestore_selectAll);

Finder _row(String label) => find.widgetWithText(CheckboxListTile, label);

Finder get _filledButton => find.byWidgetPredicate((w) => w is FilledButton);

Finder get _chooseFile =>
    find.widgetWithText(MeshNavTile, _l10n.backupRestore_chooseFile);

/// Taps the show/hide button and returns whether the text is hidden after.
Future<bool> _toggleObscured(WidgetTester tester) async {
  await tester.tap(find.byType(IconButton));
  await tester.pump();
  return tester.widget<EditableText>(find.byType(EditableText)).obscureText;
}

bool _textIsCut(WidgetTester tester, String text) {
  final paragraph = tester.renderObject<RenderParagraph>(
    find.descendant(of: find.text(text), matching: find.byType(RichText)),
  );
  return paragraph.didExceedMaxLines;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final tempDir = Directory.systemTemp.createTempSync('backup_pages_test');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (call) async => tempDir.path,
  );

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
  });

  testWidgets('Settings opens Create Backup, Restore Backup and Export Data', (
    tester,
  ) async {
    await tester.pumpWidget(_app(const SettingsScreen()));
    await _settle(tester);

    final rows = {
      _l10n.backupRestore_backup: BackupCreateScreen,
      _l10n.backupRestore_restoreTitle: BackupRestoreScreen,
      _l10n.settings_exportData: ExportScreen,
    };
    for (final MapEntry(key: title, value: page) in rows.entries) {
      await tester.scrollUntilVisible(
        find.text(title),
        200,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await _settle(tester);
      await tester.tap(find.text(title));
      await _settle(tester);
      expect(find.byType(page), findsOneWidget, reason: title);
      // The page's own title is in its app bar.
      expect(
        find.descendant(of: find.byType(AppBar), matching: find.text(title)),
        findsOneWidget,
        reason: title,
      );
      await tester.pageBack();
      await _settle(tester);
      expect(find.byType(page), findsNothing, reason: title);
    }
    await tester.pumpWidget(const SizedBox());
  });

  test('backupErrorText drops the Dart error prefixes', () {
    expect(backupErrorText(StateError('Connect first')), 'Connect first');
    expect(backupErrorText(const FormatException('Bad file')), 'Bad file');
    expect(backupErrorText(Exception('Other')), 'Exception: Other');
  });

  testWidgets('both pages show the offline banner without a radio', (
    tester,
  ) async {
    for (final page in const [BackupCreateScreen(), BackupRestoreScreen()]) {
      await tester.pumpWidget(_app(page));
      await tester.pump();
      expect(find.byType(RadioDisconnectedBanner), findsOneWidget);
      expect(find.text(_l10n.repeater_radioDisconnected), findsOneWidget);
    }
  });

  group('BackupItemList', () {
    Future<void> pumpList(
      WidgetTester tester, {
      Set<BackupItem> selected = const {},
      Set<BackupItem>? available,
      bool enabled = true,
      void Function(BackupItem, bool)? onChanged,
    }) async {
      _setView(tester, const Size(800, 3000));
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: SingleChildScrollView(
              child: BackupItemList(
                selected: selected,
                available: available,
                enabled: enabled,
                onChanged: onChanged ?? (_, _) {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    final groupHeaders = [
      _l10n.settings_nodeSettings,
      _l10n.settings_location,
      _l10n.backupRestore_contacts,
      _l10n.backupRestore_channels,
      _l10n.backupRestore_messages,
      _l10n.settings_appSettings,
    ].map((label) => label.toUpperCase());

    testWidgets('lists every group and item by default', (tester) async {
      await pumpList(tester);
      for (final header in groupHeaders) {
        expect(find.text(header), findsOneWidget, reason: header);
      }
      expect(_rows, findsNWidgets(BackupItem.values.length));
    });

    testWidgets('available hides other items and empty groups', (tester) async {
      await pumpList(
        tester,
        available: {BackupItem.deviceName, BackupItem.bookmarks},
      );
      expect(_rows, findsNWidgets(2));
      expect(_row(_l10n.backupRestore_deviceName), findsOneWidget);
      expect(_row(_l10n.backupRestore_bookmarks), findsOneWidget);
      expect(_row(_l10n.backupRestore_privateKey), findsNothing);
      expect(
        find.text(_l10n.settings_nodeSettings.toUpperCase()),
        findsOneWidget,
      );
      expect(
        find.text(_l10n.backupRestore_messages.toUpperCase()),
        findsOneWidget,
      );
      for (final header in [
        _l10n.settings_location,
        _l10n.backupRestore_contacts,
        _l10n.backupRestore_channels,
        _l10n.settings_appSettings,
      ]) {
        expect(find.text(header.toUpperCase()), findsNothing, reason: header);
      }
    });

    testWidgets('enabled false disables every row', (tester) async {
      var calls = 0;
      await pumpList(tester, enabled: false, onChanged: (_, _) => calls++);
      for (final tile in tester.widgetList<CheckboxListTile>(_rows)) {
        expect(tile.onChanged, isNull);
      }
      expect(tester.widget<CheckboxListTile>(_selectAll).onChanged, isNull);
      await tester.tap(_row(_l10n.backupRestore_deviceName));
      await tester.tap(_selectAll);
      await tester.pump();
      expect(calls, 0);
    });

    testWidgets('Select All shows whether all, some or none are ticked', (
      tester,
    ) async {
      bool? box() => tester.widget<CheckboxListTile>(_selectAll).value;
      await pumpList(tester);
      expect(box(), isFalse);
      await pumpList(tester, selected: {BackupItem.deviceName});
      expect(box(), isNull);
      await pumpList(tester, selected: BackupItem.values.toSet());
      expect(box(), isTrue);
    });

    testWidgets('Select All ticks every item, sensitive ones included', (
      tester,
    ) async {
      final changes = <(BackupItem, bool)>[];
      await pumpList(
        tester,
        selected: {BackupItem.deviceName},
        onChanged: (item, value) => changes.add((item, value)),
      );
      await tester.tap(_selectAll);
      await tester.pump();
      // Only the unticked items change.
      expect(changes.toSet(), {
        for (final item in BackupItem.values)
          if (item != BackupItem.deviceName) (item, true),
      });
      expect(changes, hasLength(BackupItem.values.length - 1));
    });

    testWidgets('Select All clears every item once all are ticked', (
      tester,
    ) async {
      final changes = <(BackupItem, bool)>[];
      await pumpList(
        tester,
        selected: BackupItem.values.toSet(),
        onChanged: (item, value) => changes.add((item, value)),
      );
      await tester.tap(_selectAll);
      await tester.pump();
      expect(changes.map((c) => c.$1).toSet(), BackupItem.values.toSet());
      expect(changes.every((c) => !c.$2), isTrue);
    });

    testWidgets('Select All only ticks the listed items', (tester) async {
      final changes = <(BackupItem, bool)>[];
      await pumpList(
        tester,
        available: {BackupItem.contacts, BackupItem.bookmarks},
        onChanged: (item, value) => changes.add((item, value)),
      );
      await tester.tap(_selectAll);
      await tester.pump();
      expect(changes.toSet(), {
        (BackupItem.contacts, true),
        (BackupItem.bookmarks, true),
      });
    });

    testWidgets('onChanged reports the tapped item and its new value', (
      tester,
    ) async {
      final changes = <(BackupItem, bool)>[];
      await pumpList(
        tester,
        selected: {BackupItem.deviceName},
        onChanged: (item, value) => changes.add((item, value)),
      );
      await tester.tap(_row(_l10n.backupRestore_deviceName));
      await tester.tap(_row(_l10n.backupRestore_bookmarks));
      await tester.pump();
      expect(changes, [
        (BackupItem.deviceName, false),
        (BackupItem.bookmarks, true),
      ]);
    });

    testWidgets('rows are at least 48 high with a 24px icon', (tester) async {
      await pumpList(tester);
      for (final row in _rows.evaluate()) {
        final finder = find.byElementPredicate((e) => e == row);
        expect(tester.getSize(finder).height, greaterThanOrEqualTo(48));
        final icon = find.descendant(of: finder, matching: find.byType(Icon));
        expect(icon, findsOneWidget);
        expect(tester.getSize(icon), const Size(24, 24));
      }
    });
  });

  group('Create Backup', () {
    testWidgets('sensitive items start unticked and the rest ticked', (
      tester,
    ) async {
      _setView(tester, const Size(800, 3000));
      await tester.pumpWidget(_app(const BackupCreateScreen()));
      await tester.pump();
      final sensitive = {
        _l10n.backupRestore_privateKey,
        _l10n.backupRestore_ipfsKey,
        _l10n.backupRestore_stadiaMapKey,
      };
      final tiles = tester.widgetList<CheckboxListTile>(_rows).toList();
      expect(tiles, hasLength(BackupItem.values.length));
      for (final tile in tiles) {
        final label = (tile.title! as Text).data!;
        expect(tile.value, !sensitive.contains(label), reason: label);
      }
    });

    testWidgets('Create Backup is disabled with nothing selected', (
      tester,
    ) async {
      _setView(tester, const Size(800, 3000));
      await tester.pumpWidget(_app(const BackupCreateScreen()));
      await tester.pump();
      expect(tester.widget<FilledButton>(_filledButton).onPressed, isNotNull);

      for (final row in _rows.evaluate().toList()) {
        if ((row.widget as CheckboxListTile).value == true) {
          await tester.tap(find.byElementPredicate((e) => e == row));
        }
      }
      await tester.pump();
      expect(
        tester.widgetList<CheckboxListTile>(_rows).every((t) => !t.value!),
        isTrue,
      );
      expect(tester.widget<FilledButton>(_filledButton).onPressed, isNull);
    });

    testWidgets('shows the warning and the password note in full', (
      tester,
    ) async {
      _setView(tester, const Size(320, 568));
      await tester.pumpWidget(_app(const BackupCreateScreen()));
      await tester.pump();
      // The warning card comes first, above the password section.
      final warning = find.text(_l10n.backupRestore_backupWarning);
      final note = find.text(_l10n.backupRestore_passwordOptional);
      expect(warning, findsOneWidget);
      expect(note, findsOneWidget);
      expect(
        tester.getTopLeft(warning).dy,
        lessThan(tester.getTopLeft(note).dy),
      );
      expect(_textIsCut(tester, _l10n.backupRestore_backupWarning), isFalse);
      expect(_textIsCut(tester, _l10n.backupRestore_passwordOptional), isFalse);
    });

    testWidgets('the password can be shown and hidden', (tester) async {
      await tester.pumpWidget(_app(const BackupCreateScreen()));
      await tester.pump();
      expect(find.text(_l10n.login_password), findsWidgets);
      expect(find.byTooltip(_l10n.login_showPassword), findsOneWidget);
      expect(await _toggleObscured(tester), isFalse);
      expect(find.byTooltip(_l10n.login_hidePassword), findsOneWidget);
      expect(await _toggleObscured(tester), isTrue);
    });
  });

  group('Restore Backup', () {
    // The file the fake file picker returns, or null for a cancelled pick.
    String? pickedPath;
    setUp(() {
      pickedPath = null;
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/file_selector'),
        (call) async => call.method == 'openFile' && pickedPath != null
            ? [pickedPath!]
            : null,
      );
    });
    tearDown(
      () => messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/file_selector'),
        null,
      ),
    );

    Future<String> writeFile(String name, String contents) async {
      final file = File('${tempDir.path}/$name');
      await file.writeAsString(contents);
      return file.path;
    }

    Future<void> pumpAndPick(WidgetTester tester, String path) async {
      _setView(tester, const Size(800, 3000));
      pickedPath = path;
      await tester.pumpWidget(_app(const BackupRestoreScreen()));
      await tester.pump();
      await tester.tap(_chooseFile);
      // Waits until the file is inspected: items or the password field.
      await _waitFor(
        tester,
        () =>
            _rows.evaluate().isNotEmpty ||
            find.byType(TextField).evaluate().isNotEmpty,
      );
      // Lets the password field finish sliding in.
      await _settle(tester);
    }

    // A plaintext backup with the given items, picked on the page.
    Future<void> pumpPlain(WidgetTester tester, List<BackupItem> items) async {
      final contents = await tester.runAsync(
        () => BackupService.encodeBackup({
          'format': 'meshcore-open-backup',
          'version': 1,
          'sourcePublicKey': '0011223344',
          'items': [for (final item in items) item.name],
          'sections': <String, Object?>{},
        }, password: ''),
      );
      final path = await tester.runAsync(
        () => writeFile('plain.json', contents!),
      );
      await pumpAndPick(tester, path!);
    }

    Future<void> tapRestore(WidgetTester tester) async {
      await tester.tap(_filledButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('starts with the info card and the Choose File row', (
      tester,
    ) async {
      await tester.pumpWidget(_app(const BackupRestoreScreen()));
      await tester.pump();
      final info = find.text(_l10n.backupRestore_restoreInfo);
      final header = find.text(_l10n.backupRestore_fileHeader.toUpperCase());
      expect(info, findsOneWidget);
      expect(header, findsOneWidget);
      expect(
        tester.getTopLeft(info).dy,
        lessThan(tester.getTopLeft(header).dy),
      );
      expect(_chooseFile, findsOneWidget);
      expect(
        find.descendant(
          of: _chooseFile,
          matching: find.text(_l10n.backupRestore_chooseFileHint),
        ),
        findsOneWidget,
      );
      expect(_rows, findsNothing);
      expect(_selectAll, findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(_filledButton, findsNothing);
    });

    testWidgets('a plaintext backup lists its items without a password', (
      tester,
    ) async {
      final contents = await tester.runAsync(
        () => BackupService.encodeBackup({
          'format': 'meshcore-open-backup',
          'version': 1,
          'sourcePublicKey': '0011223344',
          'items': [BackupItem.deviceName.name, BackupItem.bookmarks.name],
          'sections': <String, Object?>{},
        }, password: ''),
      );
      final path = await tester.runAsync(
        () => writeFile('plain.json', contents!),
      );
      await pumpAndPick(tester, path!);

      // The row shows the file name in place of the hint.
      expect(
        find.descendant(of: _chooseFile, matching: find.text('plain.json')),
        findsOneWidget,
      );
      expect(find.text(_l10n.backupRestore_chooseFileHint), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(_rows, findsNWidgets(2));
      expect(_selectAll, findsOneWidget);
      expect(_row(_l10n.backupRestore_deviceName), findsOneWidget);
      expect(_row(_l10n.backupRestore_bookmarks), findsOneWidget);
      // Items stored on the radio start unticked, app items ticked.
      expect(
        tester
            .widget<CheckboxListTile>(_row(_l10n.backupRestore_deviceName))
            .value,
        isFalse,
      );
      expect(
        tester
            .widget<CheckboxListTile>(_row(_l10n.backupRestore_bookmarks))
            .value,
        isTrue,
      );
      expect(tester.widget<FilledButton>(_filledButton).onPressed, isNotNull);
    });

    testWidgets('an unreadable file asks for a password and lists nothing', (
      tester,
    ) async {
      final path = await tester.runAsync(
        () => writeFile('broken.json', 'not a backup'),
      );
      await pumpAndPick(tester, path!);

      expect(find.byType(TextField), findsOneWidget);
      // No hint before a password is tried.
      expect(find.text(_l10n.backupRestore_importUnavailable), findsNothing);
      expect(_rows, findsNothing);
      expect(tester.widget<FilledButton>(_filledButton).onPressed, isNull);

      await tester.enterText(find.byType(TextField), 'wrong');
      await tester.pump(const Duration(milliseconds: 400));
      await _waitFor(
        tester,
        () => find
            .text(_l10n.backupRestore_importUnavailable)
            .evaluate()
            .isNotEmpty,
      );
      expect(find.text(_l10n.backupRestore_importUnavailable), findsOneWidget);
      expect(_rows, findsNothing);
    });

    testWidgets('the password can be shown and hidden', (tester) async {
      final path = await tester.runAsync(
        () => writeFile('broken.json', 'not a backup'),
      );
      await pumpAndPick(tester, path!);
      expect(find.byTooltip(_l10n.login_showPassword), findsOneWidget);
      expect(await _toggleObscured(tester), isFalse);
      expect(find.byTooltip(_l10n.login_hidePassword), findsOneWidget);
      expect(await _toggleObscured(tester), isTrue);
    });

    testWidgets('Restore Selected asks first, and Cancel changes nothing', (
      tester,
    ) async {
      await pumpPlain(tester, [BackupItem.bookmarks]);
      await tapRestore(tester);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        find.text(_l10n.backupRestore_confirmRestoreTitle),
        findsOneWidget,
      );
      expect(
        find.text(_l10n.backupRestore_confirmRestoreMessage),
        findsOneWidget,
      );
      expect(find.text(_l10n.backupRestore_replaceIdentityTitle), findsNothing);

      await tester.tap(find.text(_l10n.common_cancel));
      await _settle(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      expect(
        find.descendant(of: _chooseFile, matching: find.text('plain.json')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<CheckboxListTile>(_row(_l10n.backupRestore_bookmarks))
            .value,
        isTrue,
      );
      expect(tester.widget<FilledButton>(_filledButton).onPressed, isNotNull);
    });

    testWidgets('with the private key ticked, only the identity dialog shows', (
      tester,
    ) async {
      await pumpPlain(tester, [BackupItem.privateKey, BackupItem.bookmarks]);
      await tester.tap(_row(_l10n.backupRestore_privateKey));
      await tester.pump();
      await tapRestore(tester);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        find.text(_l10n.backupRestore_replaceIdentityTitle),
        findsOneWidget,
      );
      expect(
        find.text(_l10n.backupRestore_replaceIdentityMessage),
        findsOneWidget,
      );
      expect(find.text(_l10n.backupRestore_confirmRestoreTitle), findsNothing);
      await tester.tap(find.text(_l10n.common_cancel));
      await _settle(tester);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('a restore refused offline shows the reason without a prefix', (
      tester,
    ) async {
      await pumpPlain(tester, [BackupItem.bookmarks]);
      await tapRestore(tester);
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text(_l10n.backupRestore_restore),
        ),
      );
      await _waitFor(tester, () => find.byType(SnackBar).evaluate().isNotEmpty);
      final message = tester
          .widget<Text>(
            find.descendant(
              of: find.byType(SnackBar),
              matching: find.textContaining(
                _l10n.backupRestore_failed('').trim(),
              ),
            ),
          )
          .data!;
      expect(message, isNot(contains('Bad state')));
      expect(
        message,
        _l10n.backupRestore_failed(
          'Connect to the radio to back up or restore its settings',
        ),
      );
    });

    testWidgets('the password helper is not cut on a small phone', (
      tester,
    ) async {
      final path = await tester.runAsync(
        () => writeFile('broken.json', 'not a backup'),
      );
      await pumpAndPick(tester, path!);
      await tester.enterText(find.byType(TextField), 'wrong');
      await tester.pump(const Duration(milliseconds: 400));
      await _waitFor(
        tester,
        () => find
            .text(_l10n.backupRestore_importUnavailable)
            .evaluate()
            .isNotEmpty,
      );
      _setView(tester, const Size(320, 568));
      await tester.pump();
      expect(
        _textIsCut(tester, _l10n.backupRestore_importUnavailable),
        isFalse,
      );
    });

    testWidgets('an encrypted backup lists its items after the password', (
      tester,
    ) async {
      final contents = await tester.runAsync(
        () => BackupService.encodeBackup({
          'format': 'meshcore-open-backup',
          'version': 1,
          'sourcePublicKey': '0011223344',
          'items': [BackupItem.deviceName.name, BackupItem.bookmarks.name],
          'sections': <String, Object?>{},
        }, password: 'right'),
      );
      final path = await tester.runAsync(
        () => writeFile('encrypted.json', contents!),
      );
      await pumpAndPick(tester, path!);
      expect(find.byType(TextField), findsOneWidget);
      expect(_rows, findsNothing);

      await tester.enterText(find.byType(TextField), 'right');
      // The page waits 350 ms after typing before it inspects the file.
      await tester.pump(const Duration(milliseconds: 400));
      await _waitFor(tester, () => _rows.evaluate().isNotEmpty);

      expect(_rows, findsNWidgets(2));
      expect(_row(_l10n.backupRestore_deviceName), findsOneWidget);
      expect(_row(_l10n.backupRestore_bookmarks), findsOneWidget);
      // Restore defaults: items stored on the radio start unticked.
      expect(
        tester
            .widget<CheckboxListTile>(_row(_l10n.backupRestore_deviceName))
            .value,
        isFalse,
      );
      expect(
        tester
            .widget<CheckboxListTile>(_row(_l10n.backupRestore_bookmarks))
            .value,
        isTrue,
      );
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text(_l10n.backupRestore_importUnavailable), findsNothing);
      expect(tester.widget<FilledButton>(_filledButton).onPressed, isNotNull);

      // A changed password can't be used until it has been checked, and the
      // field shows its spinner meanwhile.
      final fieldSpinner = find.descendant(
        of: find.byType(BackupPasswordField),
        matching: find.byType(CircularProgressIndicator),
      );
      expect(fieldSpinner, findsNothing);
      await tester.enterText(find.byType(TextField), 'rightx');
      await tester.pump();
      expect(tester.widget<FilledButton>(_filledButton).onPressed, isNull);
      expect(fieldSpinner, findsOneWidget);
      await tester.enterText(find.byType(TextField), 'right');
      await tester.pump(const Duration(milliseconds: 400));
      await _waitFor(
        tester,
        () => tester.widget<FilledButton>(_filledButton).onPressed != null,
      );
      expect(tester.widget<FilledButton>(_filledButton).onPressed, isNotNull);
      expect(fieldSpinner, findsNothing);
    });

    testWidgets('choosing another file hides the password and clears it', (
      tester,
    ) async {
      final paths = await tester.runAsync(() async {
        final encrypted = await BackupService.encodeBackup({
          'format': 'meshcore-open-backup',
          'version': 1,
          'sourcePublicKey': '0011223344',
          'items': [BackupItem.bookmarks.name],
          'sections': <String, Object?>{},
        }, password: 'right');
        final plain = await BackupService.encodeBackup({
          'format': 'meshcore-open-backup',
          'version': 1,
          'sourcePublicKey': '0011223344',
          'items': [BackupItem.deviceName.name],
          'sections': <String, Object?>{},
        }, password: '');
        return (
          await writeFile('encrypted.json', encrypted),
          await writeFile('plain.json', plain),
        );
      });
      final (encryptedPath, plainPath) = paths!;
      await pumpAndPick(tester, encryptedPath);
      await tester.enterText(find.byType(TextField), 'typed');
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(TextField), findsOneWidget);

      // A plaintext file: no password field, and its own items.
      pickedPath = plainPath;
      await tester.tap(_chooseFile);
      await _waitFor(tester, () => _rows.evaluate().isNotEmpty);
      expect(find.text('plain.json'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(_rows, findsOneWidget);
      expect(_row(_l10n.backupRestore_deviceName), findsOneWidget);

      // The encrypted file again: the typed password is gone.
      pickedPath = encryptedPath;
      await tester.tap(_chooseFile);
      await _waitFor(
        tester,
        () => find.byType(TextField).evaluate().isNotEmpty,
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      expect(_rows, findsNothing);
    });
  });
}
