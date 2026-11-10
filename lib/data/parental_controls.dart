import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../sources/source.dart';
import 'profile_pin.dart';

/// Device-local access controls. They never travel with provider credentials
/// or source/cloud exports. Existing profile PINs remain independent.
class ParentalRules {
  const ParentalRules({
    this.verifier,
    this.lockSettings = true,
    this.channels = const {},
    this.categories = const {},
  });

  final String? verifier;
  final bool lockSettings;
  final Set<String> channels;
  final Set<String> categories;
  bool get enabled => verifier != null;

  static String channelKey(String sourceId, String channelId) =>
      jsonEncode([sourceId, channelId]);
  static String categoryKey(String sourceId, ContentKind kind, String id) =>
      jsonEncode([
        sourceId,
        kind == ContentKind.episode ? 'series' : kind.name,
        id,
      ]);

  bool protects(
    String sourceId,
    String itemId, {
    String? categoryId,
    ContentKind kind = ContentKind.live,
  }) =>
      enabled &&
      ((kind == ContentKind.live &&
              channels.contains(channelKey(sourceId, itemId))) ||
          (categoryId != null &&
              categories.contains(categoryKey(sourceId, kind, categoryId))) ||
          // Some provider/search rows omit categories. Unknown ancestry must
          // not bypass that source's category locks, including cached episodes.
          ((categoryId == null || categoryId.isEmpty) &&
              categoryIds(
                sourceId,
                kind == ContentKind.episode ? ContentKind.series : kind,
              ).isNotEmpty));

  Set<String> categoryIds(String sourceId, ContentKind kind) => {
    for (final key in categories)
      if (jsonDecode(key) case final List parts)
        if (parts.length == 3 && parts[0] == sourceId && parts[1] == kind.name)
          parts[2] as String,
  };

  ParentalRules copyWith({
    String? verifier,
    bool? lockSettings,
    Set<String>? channels,
    Set<String>? categories,
  }) => ParentalRules(
    verifier: verifier ?? this.verifier,
    lockSettings: lockSettings ?? this.lockSettings,
    channels: channels ?? this.channels,
    categories: categories ?? this.categories,
  );

  Map<String, Object?> toJson() => {
    'version': 1,
    'verifier': verifier,
    'lockSettings': lockSettings,
    'channels': channels.toList(),
    'categories': categories.toList(),
  };

  factory ParentalRules.fromJson(Object? value) {
    // A damaged/future persisted policy must never silently disable controls.
    if (value is! Map ||
        value['version'] != 1 ||
        value['lockSettings'] is! bool ||
        value['channels'] is! List ||
        value['categories'] is! List ||
        (value['verifier'] != null && value['verifier'] is! String)) {
      throw const FormatException('Parental controls cannot be read.');
    }
    Set<String> keys(Object? raw, int length) {
      if (raw is! List || raw.any((item) => item is! String)) {
        throw const FormatException('Invalid parental control entries.');
      }
      for (final key in raw.cast<String>()) {
        final parts = jsonDecode(key);
        if (parts is! List ||
            parts.length != length ||
            parts.any((part) => part is! String)) {
          throw const FormatException('Invalid parental control identity.');
        }
      }
      return raw.cast<String>().toSet();
    }

    final verifier = value['verifier'] as String?;
    if (verifier != null && !isProfilePinVerifier(verifier)) {
      throw const FormatException('Unsupported parental PIN format.');
    }
    return ParentalRules(
      verifier: verifier,
      lockSettings: value['lockSettings'] as bool,
      channels: keys(value['channels'], 2),
      categories: keys(value['categories'], 3),
    );
  }
}

class ParentalControlService extends ChangeNotifier {
  ParentalControlService({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static final instance = ParentalControlService();
  static const storageKey = 'tvbro_parental_controls_v1';
  final FlutterSecureStorage _storage;
  ParentalRules _rules = const ParentalRules();
  Future<void>? _loading;
  bool _initialized = false;
  bool _unlocked = false;
  bool _failed = false;
  int _revision = 0;

  ParentalRules get rules => _rules;
  bool get unlocked => _unlocked;
  bool get unavailable => _failed;
  int get revision => _revision;

  Future<void> ensureInitialized() {
    if (_initialized) return Future<void>.value();
    return _loading ??= _load();
  }

  /// Re-read a restored policy and revoke any unlock from the previous setup.
  Future<void> reload() async {
    _unlocked = false;
    _initialized = false;
    _loading = null;
    await ensureInitialized();
  }

  Future<void> _load() async {
    try {
      final raw = await _storage.read(key: storageKey);
      _rules = raw == null
          ? const ParentalRules()
          : ParentalRules.fromJson(jsonDecode(raw));
      _failed = false;
      _initialized = true;
    } catch (_) {
      _failed = true;
      rethrow;
    } finally {
      _changed();
    }
  }

  bool allows(
    String sourceId,
    String itemId, {
    String? categoryId,
    ContentKind kind = ContentKind.live,
  }) =>
      !_failed &&
      (_unlocked ||
          !_rules.protects(
            sourceId,
            itemId,
            categoryId: categoryId,
            kind: kind,
          ));

  bool allowsCategory(String sourceId, ContentKind kind, String categoryId) =>
      allows(sourceId, '', categoryId: categoryId, kind: kind);

  /// Called only after the existing PIN dialog verifies the current verifier.
  void unlock(String verifiedVerifier) {
    if (_failed || verifiedVerifier != _rules.verifier) return;
    _unlocked = true;
    _changed();
  }

  void lock() {
    if (!_unlocked) return;
    _unlocked = false;
    _changed();
  }

  Future<void> save(ParentalRules next) async {
    // Never publish a setting that failed to reach protected storage.
    await _storage.write(key: storageKey, value: jsonEncode(next.toJson()));
    _rules = next;
    _failed = false;
    _unlocked = false;
    _changed();
  }

  void _changed() {
    _revision++;
    notifyListeners();
  }
}
