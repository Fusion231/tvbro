import 'package:flutter/foundation.dart';

import '../data/library_repository.dart';
import '../sources/source.dart';

/// Owns the user's favorited item ids per [ContentKind] (live channels / movies
/// / series), backed by [AppDatabase] and keyed by the source. A
/// [ChangeNotifier] so favorite badges and the "Favorites" category entry
/// rebuild via the screen's listener instead of a `setState` in the screen.
///
/// Deliberately *not* the "last favorite removed → fall back to the All view"
/// handling: that's tied to the per-kind category selection (the screen's
/// `_categoryId` / the media controllers), which this class doesn't own.
/// [toggle] reports whether the kind's set emptied so the screen can apply it.
class FavoritesController extends ChangeNotifier {
  final LibraryRepository repo;

  FavoritesController({required this.repo});

  final Map<ContentKind, Set<String>> _byKind = {};
  final Map<ContentKind, Future<void>> _pending = {};
  bool _disposed = false;

  /// Favorited ids for [kind] (empty set if none loaded yet).
  Set<String> ids(ContentKind kind) => _byKind[kind] ?? const <String>{};

  bool isFavorite(ContentKind kind, String id) => ids(kind).contains(id);

  /// (Re)load the favorites for [kind] from the database.
  Future<void> load(ContentKind kind) => _enqueue(kind, () async {
    final loaded = await repo.db.readFavoriteIds(repo.source.id, kind);
    _byKind[kind] = loaded;
    if (!_disposed) notifyListeners();
  });

  /// Toggle [id] for [kind] and persist. Returns whether the kind's set is now
  /// empty (the screen uses this to fall back off the Favorites view).
  Future<bool> toggle(ContentKind kind, String id) => _enqueue(kind, () async {
    final set = {...ids(kind)};
    final nowFavorite = !set.contains(id);
    if (nowFavorite) {
      set.add(id);
    } else {
      set.remove(id);
    }
    await repo.db.setFavorite(repo.source.id, kind, id, nowFavorite);
    // Queued writes still need the committed state after the UI is disposed.
    _byKind[kind] = set;
    if (!_disposed) notifyListeners();
    return set.isEmpty;
  });

  Future<T> _enqueue<T>(ContentKind kind, Future<T> Function() action) {
    // Derive each toggle from the previous committed state. Reads join the
    // same queue so a reload cannot overwrite a newer favorite change.
    final result = (_pending[kind] ?? Future<void>.value()).then(
      (_) => action(),
    );
    // Report a failed operation to its caller without blocking later taps.
    _pending[kind] = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
