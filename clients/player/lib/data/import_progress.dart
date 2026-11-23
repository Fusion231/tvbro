import 'dart:async';

enum ImportProgressStage { waiting, downloading, processing, saving }

final _importProgressKey = Object();

bool get isTrackingImportProgress => Zone.current[_importProgressKey] != null;

/// Reports work within this import and ignores work that outlives it.
Future<T> trackImportProgress<T>(
  Future<T> Function() run,
  void Function(ImportProgressStage) onStage,
) async {
  void Function(ImportProgressStage)? listener = onStage;
  ImportProgressStage? last;
  try {
    return await runZoned(
      run,
      zoneValues: {
        _importProgressKey: (ImportProgressStage stage) {
          if (stage == last) return;
          last = stage;
          listener?.call(stage);
        },
      },
    );
  } finally {
    listener = null;
  }
}

void reportImportProgress(ImportProgressStage stage) {
  final listener =
      Zone.current[_importProgressKey] as void Function(ImportProgressStage)?;
  listener?.call(stage);
}
