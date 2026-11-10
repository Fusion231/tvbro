import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart'
    show FlutterSecureStorage;
import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/data/app_backup.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/parental_controls.dart';
import 'package:iptvs/l10n/app_language.dart';
import 'package:iptvs/screens/backup_screen.dart';
import 'package:iptvs/widgets/tv_text_field.dart';

class _Picker extends FilePickerPlatform {
  PlatformFile? file;
  FileType? selectedType;

  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    selectedType = type;
    return file;
  }
}

final class _OversizedFile extends PlatformFile {
  bool read = false;

  @override
  String get name => 'large.tvbro';
  @override
  Uri get uri => Uri.parse('file:///large.tvbro');
  @override
  Never get xFile => throw UnimplementedError();
  @override
  int lengthSync() => AppBackupService.maxFileBytes + 1;
  @override
  Future<int> length() async => lengthSync();
  @override
  Future<Uint8List> readAsBytes() async {
    read = true;
    return Uint8List(0);
  }

  @override
  Stream<Uint8List> readAsByteStream() {
    read = true;
    return Stream.value(Uint8List(0));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late AppDatabase db;
  late FilePickerPlatform previousPicker;
  late _Picker picker;

  setUpAll(() async {
    FlutterSecureStorage.setMockInitialValues({});
    directory = Directory.systemTemp.createTempSync('tvbro_backup_ui_');
    db = await AppDatabase.openAt('${directory.path}/test.db');
    await ParentalControlService.instance.ensureInitialized();
  });

  tearDownAll(() async {
    await db.close();
    directory.deleteSync(recursive: true);
  });

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await ParentalControlService.instance.save(const ParentalRules());
    AppLanguageController.instance.preview(AppLanguage.english);
    previousPicker = FilePickerPlatform.instance;
    picker = _Picker();
    FilePickerPlatform.instance = picker;
  });

  tearDown(() => FilePickerPlatform.instance = previousPicker);

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(home: BackupScreen(db: db)));
  }

  Future<void> enterPassword(
    WidgetTester tester,
    int index,
    String value,
  ) async {
    final field = find.byType(TextField).at(index);
    // Activate TvTextField's editor before changing its input connection.
    await tester.tap(find.byType(TvTextField).at(index));
    await tester.pump();
    await tester.enterText(field, value);
    await tester.pump();
    expect(tester.widget<TextField>(field).controller!.text, value);
  }

  testWidgets(
    'new backup requires matching passwords of at least eight characters',
    (tester) async {
      await open(tester);
      await tester.tap(find.text('Create backup'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await enterPassword(tester, 0, 'short');
      await tester.tap(find.text('Continue'));
      await tester.pump();
      expect(find.text('Use at least 8 characters.'), findsOneWidget);

      await enterPassword(tester, 0, 'long password');
      await enterPassword(tester, 1, 'different password');
      await tester.tap(find.text('Continue'));
      await tester.pump();
      expect(find.text('Passwords do not match.'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('oversized import is rejected before reading the file', (
    tester,
  ) async {
    final file = _OversizedFile();
    picker.file = file;
    await open(tester);
    await tester.tap(find.text('Restore from file'));
    await tester.pumpAndSettle();
    expect(find.text('Backup files can be at most 32 MB.'), findsOneWidget);
    expect(file.read, isFalse);
    expect(picker.selectedType, FileType.any);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancelling the file picker leaves backup actions enabled', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.text('Restore from file'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });
}
