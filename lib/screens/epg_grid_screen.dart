import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';

import '../data/device_class.dart';
import '../data/library_repository.dart';
import '../sources/source.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';
import '../widgets/image_utils.dart';

typedef EpgGridSelection = ({Channel channel, Programme? programme});

/// EPG timeline grid: one row per channel, programme cells positioned on a
/// shared time axis (now − 1h → now + 24h, fixed scale).
///
/// Navigation uses an explicit **selection cursor**, not Flutter's geometry
/// traversal. The screen owns `_selectedRow` + a `_cursorTime`; the selected
/// programme on a row is the one airing at the cursor time. A single [Focus]
/// on the grid captures the D-pad and moves the selection deterministically —
/// Left/Right step programme boundaries, Up/Down change channel **keeping the
/// time column** (the way a TV guide should feel), and the screen drives the
/// pan/scroll itself. This means navigation never depends on whether a lazy
/// row or an async programme cell happens to be built, and the cells
/// themselves are cheap (no per-cell focus node / InkWell / Material), so
/// scrolling stays smooth on long, dense guides.
///
/// OK on a *current* programme plays the channel; on a *past* programme of an
/// archive-capable channel it plays catch-up; anything else shows details.
class EpgGridScreen extends StatefulWidget {
  final LibraryRepository repo;

  /// Channels to list (the caller's filtered/visible set), in display order.
  final List<Channel> channels;

  /// Plays [Channel] live (the caller owns resolution + the player route).
  final void Function(Channel channel) onPlayChannel;

  /// Plays a past [Programme] via catch-up (caller resolves the archive).
  final void Function(Channel channel, Programme programme) onPlayArchive;
  final void Function(Channel channel, Programme programme)?
  onScheduleRecording;

  /// The same guide can live inside the main TV browser. Its focus and scroll
  /// stay with that browser so categories, preview controls and Back share one
  /// navigation model.
  final bool embedded;
  final FocusNode? focusNode;
  final ScrollController? scrollController;
  final int selectedChannelIndex;
  final double rowExtent;
  final ValueChanged<EpgGridSelection>? onSelectionChanged;
  final VoidCallback? onExitLeft;
  final VoidCallback? onExitUp;
  final KeyEventResult Function(FocusNode, KeyEvent)? onUnhandledKey;

  /// Wall clock, injectable so programme changes can be tested without waiting.
  final DateTime Function() now;

  const EpgGridScreen({
    super.key,
    required this.repo,
    required this.channels,
    required this.onPlayChannel,
    required this.onPlayArchive,
    this.onScheduleRecording,
    this.embedded = false,
    this.focusNode,
    this.scrollController,
    this.selectedChannelIndex = 0,
    this.rowExtent = 52,
    this.onSelectionChanged,
    this.onExitLeft,
    this.onExitUp,
    this.onUnhandledKey,
    this.now = DateTime.now,
  });

  @override
  State<EpgGridScreen> createState() => _EpgGridScreenState();
}

class _EpgGridScreenState extends State<EpgGridScreen>
    with SingleTickerProviderStateMixin {
  static const _pxPerMinute = 4.0; // 30-min slot = 120px
  double get _rowHeight => widget.rowExtent;
  double get _channelColumnWidth => widget.embedded && isTelevision ? 232 : 168;

  late final DateTime _windowStart = _floorToHalfHour(
    widget.now().subtract(Duration(hours: widget.embedded ? 0 : 1)),
  );
  late final DateTime _windowEnd = _windowStart.add(const Duration(hours: 25));

  double get _totalWidth =>
      _windowEnd.difference(_windowStart).inMinutes * _pxPerMinute;

  /// The hour ruler is ~50 `Positioned`/`Align`/`Text` ticks whose geometry
  /// depends only on the `late final` window bounds — yet it used to be rebuilt
  /// from scratch on every `setState`, i.e. on every D-pad press. Built once and
  /// handed back by identity, so the element tree skips the whole subtree; the
  /// shared `_hOffset` translate lives in a `ValueListenableBuilder` *inside* it,
  /// so panning still repaints without rebuilding a single tick.
  late final Widget _hourHeaderWidget = _buildHourHeader();

  /// Shared horizontal offset for the header + every row.
  final ValueNotifier<double> _hOffset = ValueNotifier(0);
  late final ScrollController _vController =
      widget.scrollController ?? ScrollController();

  /// Smooth horizontal pans (D-pad reveal / jump-to-now); touch drag sets the
  /// offset directly instead.
  late final AnimationController _panController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  Animation<double>? _panTween;

  /// The grid's single D-pad focus target — cells are not individually
  /// focusable, so navigation is a pure selection model.
  late final FocusNode _gridFocus =
      widget.focusNode ?? FocusNode(debugLabel: 'epg.grid');
  final FocusNode _nowFocus = FocusNode(debugLabel: 'epg.now');

  /// Selection cursor: which channel row, and the anchor time whose programme
  /// is selected. Up/Down keep [_cursorTime] so movement holds the time column.
  int _selectedRow = 0;
  late DateTime _cursorTime = widget.now();
  bool _followNow = true;
  Timer? _programmeBoundary;

  /// The selected programme's index within the current row's list — the single
  /// source of truth for the highlight and the detail bar. Left/Right step this
  /// directly (pure index stepping, immune to overlapping/gappy guide data);
  /// row changes and live boundaries resolve it from [_cursorTime].
  int _selectedCol = 0;

  /// Width of the timeline area (viewport minus the channel column), cached
  /// from the body [LayoutBuilder] for the reveal/clamp math.
  double _timelineWidth = 0;

  /// Resolved per-channel programmes, loaded lazily and request-coalesced: rows
  /// built in the same frame share one `programmesForChannels` query.
  final Map<String, List<Programme>> _programmes = {};
  final _rowLayouts =
      <
        String,
        ({
          List<Programme> programmes,
          String name,
          AppLanguage language,
          List<_CellLayout> layouts,
        })
      >{};
  final Set<String> _requested = {};
  final Set<String> _pendingBatch = {};
  Set<String>? _retainedChannelIds;
  (List<Channel>, int, int, int)? _retentionKey;
  bool _batchScheduled = false;
  int _loadGeneration = 0;

  /// Watches for the cached guide being replaced under this screen.
  StreamSubscription<String>? _guideLanded;

  static DateTime _floorToHalfHour(DateTime t) =>
      DateTime(t.year, t.month, t.day, t.hour, t.minute < 30 ? 0 : 30);

  /// HH:mm — the one formatter for the ruler, detail bar and details dialog.
  static String _hm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  void initState() {
    super.initState();
    _nowFocus.addListener(_refreshFocus);
    _vController.addListener(_pruneProgrammeCache);
    if (widget.channels.isNotEmpty) {
      _selectedRow = widget.selectedChannelIndex.clamp(
        0,
        widget.channels.length - 1,
      );
    }
    _panController.addListener(() {
      final tween = _panTween;
      if (tween != null) _hOffset.value = tween.value;
    });
    // A row's programmes are read once and kept, which was safe while the guide
    // was always settled before any list existed. `LibraryRepository.load` now
    // refreshes it behind the channel list, so the grid can be opened *during*
    // a refresh — and would then hold whatever it read (a stale guide, or an
    // empty one on a first load) with no way to catch up short of backing out
    // and re-entering.
    _watchGuide();
    if (widget.channels.isNotEmpty) {
      _ensureLoaded(widget.channels[_selectedRow].id);
    }
    // Open at "now" minus a little context.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _pruneProgrammeCache();
      _jumpToNow();
    });
  }

  @override
  void dispose() {
    _programmeBoundary?.cancel();
    unawaited(_guideLanded?.cancel());
    _panController.dispose();
    _hOffset.dispose();
    _vController.removeListener(_pruneProgrammeCache);
    if (widget.scrollController == null) _vController.dispose();
    if (widget.focusNode == null) _gridFocus.dispose();
    _nowFocus.dispose();
    super.dispose();
  }

  void _refreshFocus() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(EpgGridScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.repo, widget.repo)) {
      _loadGeneration++;
      unawaited(_guideLanded?.cancel());
      _programmes.clear();
      _rowLayouts.clear();
      _requested.clear();
      _pendingBatch.clear();
      _retentionKey = null;
      _watchGuide();
    }
    if (widget.channels.isEmpty) {
      _selectedRow = 0;
      _pruneProgrammeCache();
      _programmeBoundary?.cancel();
      return;
    }
    final next = (widget.embedded ? widget.selectedChannelIndex : _selectedRow)
        .clamp(0, widget.channels.length - 1);
    final channelsChanged =
        !identical(widget.channels, oldWidget.channels) ||
        !identical(widget.repo, oldWidget.repo);
    if (next != _selectedRow || channelsChanged) {
      _selectedRow = next;
      _pruneProgrammeCache();
      if (_followNow) _cursorTime = widget.now();
      _ensureLoaded(widget.channels[next].id);
      final col = _resolveColForRow(next);
      _selectedCol = col >= 0 ? col : 0;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _revealRow(_selectedRow);
        _publishSelection();
      });
      _scheduleProgrammeBoundary();
    }
  }

  void _watchGuide() {
    _guideLanded = widget.repo.db.epgChanged.listen((sourceId) {
      if (sourceId == widget.repo.source.id) _reloadLoadedRows();
    });
  }

  void _publishSelection() {
    if (widget.channels.isEmpty) return;
    widget.onSelectionChanged?.call((
      channel: widget.channels[_selectedRow],
      programme: _selection?.$2,
    ));
  }

  // ── Programme loading ──────────────────────────────────────────────────────

  /// Keep guide data near the viewport, plus the selected row for its details.
  /// Widget virtualization alone does not release the programmes of old rows.
  void _pruneProgrammeCache() {
    final channels = widget.channels;
    final position = _vController.hasClients ? _vController.position : null;
    final hasViewport = position?.hasContentDimensions ?? false;
    final first = hasViewport
        ? (position!.pixels / _rowHeight).floor()
        : _selectedRow;
    final visibleRows = hasViewport
        ? (position!.viewportDimension / _rowHeight).ceil()
        : 1;
    // Include ListView's 250px cache and a small reverse-scroll buffer.
    final buffer = 8 + (250 / _rowHeight).ceil();
    final start = (first - buffer).clamp(0, channels.length);
    final end = (first + visibleRows + buffer).clamp(0, channels.length);
    final key = (channels, start, end, _selectedRow);
    if (_retentionKey == key) return;
    _retentionKey = key;
    final retained = <String>{
      for (var i = start; i < end; i++) channels[i].id,
      if (channels.isNotEmpty) channels[_selectedRow].id,
    };
    _retainedChannelIds = retained;
    _programmes.removeWhere((id, _) => !retained.contains(id));
    _rowLayouts.removeWhere((id, _) => !retained.contains(id));
    _requested.removeWhere((id) => !retained.contains(id));
    _pendingBatch.removeWhere((id) => !retained.contains(id));
  }

  void _ensureLoaded(String channelId) {
    if (_programmes.containsKey(channelId) || _requested.contains(channelId)) {
      return;
    }
    _requested.add(channelId);
    _pendingBatch.add(channelId);
    if (!_batchScheduled) {
      _batchScheduled = true;
      scheduleMicrotask(_runBatch);
    }
  }

  List<_CellLayout> _layoutsFor(Channel channel, List<Programme> programmes) {
    final language = AppLanguageController.instance.language;
    final cached = _rowLayouts[channel.id];
    if (cached != null &&
        identical(cached.programmes, programmes) &&
        cached.name == channel.name &&
        cached.language == language) {
      return cached.layouts;
    }
    final total = programmes.length;
    final layouts = [
      for (var i = 0; i < total; i++)
        _CellLayout(
          programme: programmes[i],
          left: _offsetForTime(_clampStart(programmes[i])),
          width: _cellWidth(
            programmes[i],
            _windowStart,
            _windowEnd,
            nextStart: i + 1 < total ? programmes[i + 1].start : null,
          ),
          semanticsLabel: tr(
            '{title}, {channel}, {start} to {stop}, {position} of {total}',
            {
              'title': programmes[i].title,
              'channel': channel.name,
              'start': _hm(programmes[i].start),
              'stop': _hm(programmes[i].stop),
              'position': i + 1,
              'total': total,
            },
          ),
        ),
    ];
    _rowLayouts[channel.id] = (
      programmes: programmes,
      name: channel.name,
      language: language,
      layouts: layouts,
    );
    return layouts;
  }

  /// Re-reads every row already on screen after the guide was replaced.
  ///
  /// Deliberately re-queries rather than clearing [_programmes] first: the rows
  /// are replaced in place when the query returns, so a refresh does not blink
  /// the whole grid through an empty state on its way to the new guide. Rows
  /// never loaded are left alone — [_ensureLoaded] reads them when they scroll
  /// into view, by which time they read the new guide anyway.
  void _reloadLoadedRows() {
    _pruneProgrammeCache();
    _loadGeneration++;
    // The guide can land while its first query is still running. Include that
    // request and discard its stale result, even if no row has loaded yet.
    _pendingBatch.addAll({..._programmes.keys, ..._requested});
    if (_pendingBatch.isEmpty) return;
    if (!_batchScheduled) {
      _batchScheduled = true;
      scheduleMicrotask(_runBatch);
    }
  }

  Future<void> _runBatch() async {
    _batchScheduled = false;
    _pruneProgrammeCache();
    final ids = _pendingBatch.toList();
    _pendingBatch.clear();
    if (ids.isEmpty) return;
    final generation = _loadGeneration;
    List<Programme> forId(Map<String, List<Programme>> byChannel, String id) =>
        byChannel[id] ?? const [];
    try {
      final byChannel = await widget.repo.db.programmesForChannels(
        widget.repo.source.id,
        ids,
        from: _windowStart,
        to: _windowEnd,
      );
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        for (final id in ids) {
          if (_retainedChannelIds!.contains(id)) {
            _programmes[id] = forId(byChannel, id);
          }
        }
        _resolveSelectedColOnLoad(ids);
      });
      _publishSelection();
      _scheduleProgrammeBoundary();
    } catch (_) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        for (final id in ids) {
          if (_retainedChannelIds!.contains(id)) {
            _programmes[id] = const [];
          }
        }
      });
      _publishSelection();
      _scheduleProgrammeBoundary();
    }
  }

  /// Once the *selected* row's programmes finish loading, resolve which one the
  /// held cursor time selects — so the initial selection (and the detail bar)
  /// appears as soon as row 0 loads, and a row we scrolled onto before its data
  /// arrived catches up.
  void _resolveSelectedColOnLoad(List<String> loadedIds) {
    if (widget.channels.isEmpty) return;
    final selectedId = widget.channels[_selectedRow].id;
    if (!loadedIds.contains(selectedId)) return;
    if (_followNow) _cursorTime = widget.now();
    final col = _resolveColForRow(_selectedRow);
    if (col >= 0) _selectedCol = col;
  }

  // ── Geometry / reveal ──────────────────────────────────────────────────────

  double _offsetForTime(DateTime time) =>
      time.difference(_windowStart).inMinutes * _pxPerMinute;

  double get _maxOffset =>
      (_totalWidth - _timelineWidth).clamp(0.0, double.infinity);

  /// Set the offset directly (touch drag), cancelling any running pan.
  void _panTo(double offset) {
    _panController.stop();
    _hOffset.value = offset.clamp(0.0, _maxOffset);
  }

  /// Smoothly pan to [target] (D-pad reveal / jump-to-now).
  void _animatePanTo(double target) {
    final clamped = target.clamp(0.0, _maxOffset);
    if ((clamped - _hOffset.value).abs() < 0.5) return;
    _panTween = Tween<double>(begin: _hOffset.value, end: clamped).animate(
      CurvedAnimation(parent: _panController, curve: Curves.easeOutCubic),
    );
    _panController.forward(from: 0);
  }

  /// Keep the programme at [index] of the row's [items] horizontally in view.
  ///
  /// The reveal must use the row's **painted** geometry, not the programme's
  /// own times. [_cellWidth] truncates an entry that overruns the next one's
  /// start (bad guide runtimes), and revealing without that `nextStart` let an
  /// overlong entry claim a span it never drew: one entry whose stop landed a
  /// day out asked to reveal thousands of pixels of cell, which panned the
  /// timeline to its far-right clamp and left the ~24 px cell that was actually
  /// painted — and the selection highlight with it — completely off-screen.
  /// That is the "browse right along one channel and the guide jumps somewhere
  /// with no apparent focus" report, and it needs exactly one bad entry on one
  /// channel to happen.
  void _revealProgrammeAt(List<Programme> items, int index) {
    if (index < 0 || index >= items.length) return;
    final programme = items[index];
    final left = _offsetForTime(_clampStart(programme));
    final width = _cellWidth(
      programme,
      _windowStart,
      _windowEnd,
      nextStart: index + 1 < items.length ? items[index + 1].start : null,
    );
    final offset = _hOffset.value;
    // A cell wider than the viewport can't be framed by its end: the title is
    // drawn at the left edge, so ending-aligned reveal would scroll it away and
    // leave a blank stretch of fill as the only sign of the cursor. Anchor the
    // start instead — the same answer as "it's off the left edge".
    if (left < offset || width >= _timelineWidth) {
      _animatePanTo(left - 24);
    } else if (left + width > offset + _timelineWidth) {
      _animatePanTo(left + width - _timelineWidth + 24);
    }
  }

  /// Scroll the vertical list so channel [row] sits centered in the viewport —
  /// a row that hugged the bottom edge would be covered by the detail bar.
  void _revealRow(int row, {bool animate = true}) {
    if (!_vController.hasClients) return;
    final position = _vController.position;
    final target =
        (row * _rowHeight - (position.viewportDimension - _rowHeight) / 2)
            .clamp(0.0, position.maxScrollExtent);
    if (!animate) {
      // A held arrow must reveal its row even when repeats outrun painting.
      _vController.jumpTo(target);
      return;
    }
    if ((target - position.pixels).abs() < 0.5) return;
    _vController.animateTo(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  DateTime _clampStart(Programme p) =>
      p.start.isBefore(_windowStart) ? _windowStart : p.start;

  void _jumpToNow() {
    if (!mounted) return;
    final now = widget.now();
    setState(() {
      _followNow = true;
      _cursorTime = now;
      final col = _resolveColForRow(_selectedRow);
      if (col >= 0) _selectedCol = col;
    });
    // Instant, not animated: the guide should open already at "now", and an
    // auto-started ticker here would fight the widget-test clock.
    _panTo(_offsetForTime(now) - 120);
    _publishSelection();
    _scheduleProgrammeBoundary();
  }

  bool _isAiring(Programme programme, DateTime now) =>
      !programme.start.isAfter(now) && programme.stop.isAfter(now);

  /// Wake at a guide boundary, including starts that overlap an overlong entry.
  /// Manual past/future browsing holds its time column until Now is selected.
  void _scheduleProgrammeBoundary() {
    _programmeBoundary?.cancel();
    if (!_followNow || widget.channels.isEmpty) return;
    final items = _programmes[widget.channels[_selectedRow].id];
    if (items == null) return;
    final now = widget.now();
    DateTime? boundary;
    for (final programme in items) {
      for (final time in [programme.start, programme.stop]) {
        if (time.isAfter(now) &&
            (boundary == null || time.isBefore(boundary))) {
          boundary = time;
        }
      }
    }
    if (boundary != null) {
      _programmeBoundary = Timer(
        boundary.difference(now),
        _refreshLiveSelection,
      );
    }
  }

  void _refreshLiveSelection() {
    if (!mounted || !_followNow || widget.channels.isEmpty) return;
    setState(() {
      _cursorTime = widget.now();
      final col = _resolveColForRow(_selectedRow);
      if (col >= 0) _selectedCol = col;
    });
    final items = _programmes[widget.channels[_selectedRow].id];
    if (items != null && items.isNotEmpty) {
      _revealProgrammeAt(items, _selectedCol.clamp(0, items.length - 1));
    }
    _publishSelection();
    _scheduleProgrammeBoundary();
  }

  // ── Selection / navigation ─────────────────────────────────────────────────

  /// The currently selected (channel, programme), or null when the selected
  /// row has no loaded programmes or no current entry while following live.
  (Channel, Programme)? get _selection {
    if (widget.channels.isEmpty) return null;
    final channel = widget.channels[_selectedRow];
    final items = _programmes[channel.id];
    if (items == null || items.isEmpty) return null;
    final index = _selectedCol.clamp(0, items.length - 1);
    if (_followNow && !_isAiring(items[index], widget.now())) return null;
    return (channel, items[index]);
  }

  /// Re-derive [_selectedCol] for [row] from the held [_cursorTime]. Returns the
  /// programme index, or -1 when that row has no loaded programmes yet.
  int _resolveColForRow(int row) {
    if (row < 0 || row >= widget.channels.length) return -1;
    final items = _programmes[widget.channels[row].id];
    if (items == null || items.isEmpty) return -1;
    return _selectedIndexIn(items, _cursorTime);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return widget.onUnhandledKey?.call(node, event) ?? KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (_nowFocus.hasPrimaryFocus) {
      if (key == LogicalKeyboardKey.arrowDown ||
          key == LogicalKeyboardKey.arrowLeft ||
          key == LogicalKeyboardKey.arrowRight) {
        _gridFocus.requestFocus();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowUp && widget.onExitUp != null) {
        widget.onExitUp!();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.select ||
          key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.numpadEnter ||
          key == LogicalKeyboardKey.gameButtonA ||
          key == LogicalKeyboardKey.space) {
        if (event is KeyDownEvent) {
          _jumpToNow();
          _gridFocus.requestFocus();
        }
        return KeyEventResult.handled;
      }
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      // At the top row, let focus escape upward to the AppBar action instead of
      // being trapped in the grid.
      if (_selectedRow == 0) {
        if (widget.onExitUp == null) return KeyEventResult.ignored;
        widget.onExitUp!();
        return KeyEventResult.handled;
      }
      return _moveRow(-1, animate: event is! KeyRepeatEvent);
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      return _moveRow(1, animate: event is! KeyRepeatEvent);
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      final items = widget.channels.isEmpty
          ? const <Programme>[]
          : _programmes[widget.channels[_selectedRow].id] ??
                const <Programme>[];
      if (widget.onExitLeft != null &&
          (items.isEmpty ||
              _selectedCol == 0 ||
              !(_selection?.$2.start.isAfter(widget.now()) ?? false))) {
        widget.onExitLeft!();
        return KeyEventResult.handled;
      }
      return _moveColumn(-1);
    }
    if (key == LogicalKeyboardKey.arrowRight) return _moveColumn(1);
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.gameButtonA ||
        key == LogicalKeyboardKey.space) {
      if (event is KeyDownEvent) _activateSelected();
      return KeyEventResult.handled;
    }
    return widget.onUnhandledKey?.call(node, event) ?? KeyEventResult.ignored;
  }

  /// Move the selection [delta] rows, clamped (no wrap). Keeps [_cursorTime] so
  /// the time column holds; re-derives the selected programme on the new row
  /// (the one airing at the held time) and drives the vertical scroll.
  KeyEventResult _moveRow(int delta, {bool animate = true}) {
    final channels = widget.channels;
    if (channels.isEmpty) return KeyEventResult.handled;
    final next = (_selectedRow + delta).clamp(0, channels.length - 1);
    if (next == _selectedRow) return KeyEventResult.handled;
    _ensureLoaded(channels[next].id);
    setState(() {
      _selectedRow = next;
      if (_followNow) _cursorTime = widget.now();
      // Hold the time column: pick the programme airing at [_cursorTime] on the
      // new row. When the row isn't loaded yet, _runBatch derives it on arrival.
      final col = _resolveColForRow(next);
      if (col >= 0) _selectedCol = col;
    });
    _revealRow(next, animate: animate);
    _publishSelection();
    _scheduleProgrammeBoundary();
    // The selected programme sits at the same time, so it's usually already in
    // view; reveal it anyway in case its span extends off-screen.
    final items = _programmes[channels[next].id];
    if (items != null && items.isNotEmpty) {
      _revealProgrammeAt(items, _selectedCol.clamp(0, items.length - 1));
    }
    return KeyEventResult.handled;
  }

  /// Step the selection [delta] programmes along the current row, clamped (no
  /// wrap). Pure index stepping — the highlight follows [_selectedCol], not a
  /// re-resolution of [_cursorTime], so overlapping/duplicate guide entries
  /// can't trap the cursor. [_cursorTime] tracks the new programme's start so a
  /// later Up/Down still holds the right time column.
  KeyEventResult _moveColumn(int delta) {
    final channels = widget.channels;
    if (channels.isEmpty) return KeyEventResult.handled;
    final items = _programmes[channels[_selectedRow].id];
    if (items == null || items.isEmpty) return KeyEventResult.handled;
    final current = _selectedCol.clamp(0, items.length - 1);
    final next = (current + delta).clamp(0, items.length - 1);
    if (next == current) {
      if (_selectedCol != current) setState(() => _selectedCol = current);
      return KeyEventResult.handled;
    }
    final programme = items[next];
    setState(() {
      _selectedCol = next;
      final now = widget.now();
      _followNow =
          _isAiring(programme, now) && next == _selectedIndexIn(items, now);
      _cursorTime = _followNow ? now : _clampStart(programme);
    });
    _revealProgrammeAt(items, next);
    _publishSelection();
    _scheduleProgrammeBoundary();
    return KeyEventResult.handled;
  }

  void _activateSelected() {
    // Reconcile after a suspended app or a delayed timer before handling OK.
    if (_followNow) _refreshLiveSelection();
    final selection = _selection;
    if (widget.embedded) {
      if (widget.channels.isEmpty) return;
      final programme = selection?.$2;
      if (_followNow ||
          programme == null ||
          _isAiring(programme, widget.now())) {
        if (!_followNow) {
          _followNow = true;
          _refreshLiveSelection();
        }
        widget.onPlayChannel(widget.channels[_selectedRow]);
        return;
      }
    }
    if (selection == null) return;
    _showProgrammeDetails(selection.$1, selection.$2);
  }

  /// Touch: select the tapped cell and open its details.
  void _selectAndActivate(int row, Programme programme) {
    final items = _programmes[widget.channels[row].id] ?? const [];
    final index = items.indexOf(programme);
    setState(() {
      _selectedRow = row;
      if (index >= 0) _selectedCol = index;
      final now = widget.now();
      _followNow =
          _isAiring(programme, now) && index == _selectedIndexIn(items, now);
      _cursorTime = _followNow ? now : _clampStart(programme);
    });
    _gridFocus.requestFocus();
    _publishSelection();
    _scheduleProgrammeBoundary();
    _activateSelected();
  }

  @override
  Widget build(BuildContext context) {
    final grid = LayoutBuilder(
      builder: (context, constraints) {
        _timelineWidth = (constraints.maxWidth - _channelColumnWidth).clamp(
          0.0,
          double.infinity,
        );
        return Focus(
          focusNode: _gridFocus,
          autofocus: true,
          onFocusChange: (_) => setState(() {}),
          onKeyEvent: _onKey,
          child: GestureDetector(
            onHorizontalDragUpdate: (details) =>
                _panTo(_hOffset.value - details.delta.dx),
            child: Column(
              children: [
                if (widget.embedded)
                  Container(
                    height: 38,
                    padding: const EdgeInsets.only(left: 12, right: 6),
                    decoration: BoxDecoration(
                      color: isTelevision
                          ? Colors.transparent
                          : AppColors.panel,
                      border: const Border(
                        bottom: BorderSide(color: AppColors.line),
                      ),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.view_timeline_outlined,
                          size: 16,
                          color: AppColors.textLo,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          tr('TV guide'),
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const Spacer(),
                        Text(
                          '${_cursorTime.day.toString().padLeft(2, '0')}.'
                          '${_cursorTime.month.toString().padLeft(2, '0')}',
                          style: const TextStyle(
                            color: AppColors.textLo,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(width: 12),
                        TextButton(
                          focusNode: _nowFocus,
                          onPressed: () {
                            _jumpToNow();
                            _gridFocus.requestFocus();
                          },
                          child: Text(tr('Now')),
                        ),
                      ],
                    ),
                  ),
                _hourHeaderWidget,
                const Divider(height: 1, color: AppColors.line),
                Expanded(
                  child: widget.channels.isEmpty
                      ? Center(
                          child: Text(
                            tr('No channels'),
                            style: TextStyle(color: AppColors.textLo),
                          ),
                        )
                      : ListView.builder(
                          controller: _vController,
                          scrollCacheExtent: const ScrollCacheExtent.pixels(
                            250,
                          ),
                          itemExtent: _rowHeight,
                          itemCount: widget.channels.length,
                          itemBuilder: (context, i) {
                            final channel = widget.channels[i];
                            _ensureLoaded(channel.id);
                            final programmes =
                                _programmes[channel.id] ?? const <Programme>[];
                            return _ChannelRow(
                              channel: channel,
                              programmes: programmes,
                              layouts: _layoutsFor(channel, programmes),
                              isSelectedRow: i == _selectedRow,
                              selectedIndex: i == _selectedRow
                                  ? _selectedCol
                                  : -1,
                              focused: _gridFocus.hasPrimaryFocus,
                              fontSize: widget.embedded ? 14 : 12,
                              timelineWidth: _timelineWidth,
                              channelColumnWidth: _channelColumnWidth,
                              hOffset: _hOffset,
                              clock: widget.now,
                              onTapChannel: () {
                                setState(() {
                                  _selectedRow = i;
                                  _followNow = true;
                                  _cursorTime = widget.now();
                                  _selectedCol = _resolveColForRow(i);
                                });
                                _gridFocus.requestFocus();
                                _publishSelection();
                                _scheduleProgrammeBoundary();
                                widget.onPlayChannel(channel);
                              },
                              onTapProgramme: (programme) =>
                                  _selectAndActivate(i, programme),
                            );
                          },
                        ),
                ),
                if (!widget.embedded) _focusedDetailBar(),
              ],
            ),
          ),
        );
      },
    );
    if (widget.embedded) return grid;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('TV guide')),
        actions: [
          IconButton(
            tooltip: tr('Jump to now'),
            icon: const Icon(Icons.today_rounded),
            onPressed: _jumpToNow,
          ),
        ],
      ),
      // Edge-to-edge (targetSdk 35+). Wrapping *outside* the LayoutBuilder is
      // deliberate: the timeline width and the row cursor's index→offset maths
      // are both derived from these constraints, so insetting here keeps the
      // grid's own geometry self-consistent rather than letting it compute
      // against a viewport that the system bar partly covers.
      body: SafeArea(top: false, child: grid),
    );
  }

  /// Detail strip for the selected cell: cells too narrow for their title (a
  /// 15-minute programme is ~60px wide) get their full name/time read here.
  Widget _focusedDetailBar() {
    final selection = _selection;
    if (selection == null) return const SizedBox.shrink();
    final (channel, programme) = selection;
    final description = programme.description;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      decoration: const BoxDecoration(
        color: AppColors.panel,
        border: Border(top: BorderSide(color: AppColors.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            programme.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.textHi,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '${channel.name} · ${_hm(programme.start)} – ${_hm(programme.stop)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: AppColors.textLo, fontSize: 12),
          ),
          if (description != null && description.isNotEmpty) ...[
            const SizedBox(height: 4),
            // Give the synopsis its own room (up to three lines) instead of
            // cramming it onto the meta line — the reported "make the box bigger
            // to fit all the text".
            Text(
              description,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textLo,
                fontSize: 12,
                height: 1.3,
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _showProgrammeDetails(Channel channel, Programme programme) {
    final now = widget.now();
    final isCurrent =
        !programme.start.isAfter(now) && programme.stop.isAfter(now);
    final isPast = !programme.stop.isAfter(now);
    final canCatchup = isPast && channel.hasArchive;

    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.panel,
        title: Text(
          programme.title,
          style: const TextStyle(color: AppColors.textHi),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${channel.name} · ${_hm(programme.start)} – ${_hm(programme.stop)}',
              style: const TextStyle(color: AppColors.textLo, fontSize: 13),
            ),
            if (programme.description case final description?) ...[
              const SizedBox(height: 10),
              Text(
                description,
                maxLines: 10,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: AppColors.textLo),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            // Keep a focused control on a TV remote even when no contextual
            // action button renders (a future programme, or a past one on a
            // non-archive channel) — otherwise the dialog opens with nothing
            // focused and the D-pad has no target.
            autofocus: !canCatchup && !isCurrent,
            onPressed: () => Navigator.of(context).pop(),
            child: Text(tr('Close')),
          ),
          if (!isPast && widget.onScheduleRecording != null)
            TextButton.icon(
              icon: const Icon(Icons.fiber_manual_record, size: 18),
              label: Text(tr('Schedule recording')),
              onPressed: () {
                Navigator.of(context).pop();
                widget.onScheduleRecording!(channel, programme);
              },
            ),
          if (canCatchup)
            FilledButton.icon(
              autofocus: true,
              icon: const Icon(Icons.replay_rounded, size: 18),
              label: Text(tr('Watch catch-up')),
              onPressed: () {
                Navigator.of(context).pop();
                widget.onPlayArchive(channel, programme);
              },
            )
          else if (isCurrent)
            FilledButton.icon(
              autofocus: true,
              icon: const Icon(Icons.play_arrow_rounded, size: 18),
              label: Text(tr('Play live')),
              onPressed: () {
                Navigator.of(context).pop();
                widget.onPlayChannel(channel);
              },
            ),
        ],
      ),
    );
  }

  Widget _buildHourHeader() {
    final hours = <Widget>[];
    var tick = _windowStart;
    while (tick.isBefore(_windowEnd)) {
      hours.add(
        Positioned(
          left: _offsetForTime(tick),
          top: 0,
          bottom: 0,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              _hm(tick),
              style: const TextStyle(color: AppColors.textLo, fontSize: 12),
            ),
          ),
        ),
      );
      tick = tick.add(const Duration(minutes: 30));
    }
    return SizedBox(
      height: 28,
      child: Row(
        children: [
          SizedBox(
            width: _channelColumnWidth,
            child: widget.embedded
                ? Padding(
                    padding: EdgeInsets.only(left: 12),
                    child: Text(
                      tr('Channels'),
                      style: TextStyle(color: AppColors.textLo, fontSize: 12),
                    ),
                  )
                : null,
          ),
          Expanded(
            child: ClipRect(
              child: ValueListenableBuilder<double>(
                valueListenable: _hOffset,
                builder: (context, offset, child) => Transform.translate(
                  offset: Offset(-offset, 0),
                  child: child,
                ),
                child: OverflowBox(
                  alignment: Alignment.centerLeft,
                  minWidth: 0,
                  maxWidth: _totalWidth,
                  child: SizedBox(
                    width: _totalWidth,
                    child: Stack(children: hours),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Index of the programme selected at [t]: the one whose [start, stop) contains
/// [t] — the **latest-starting** such programme when guide entries overlap, so
/// it matches the front-painted cell — else (in a gap, or before the first) the
/// last one starting at/before [t], else the first. [items] must be sorted by
/// start. -1 when empty.
int _selectedIndexIn(List<Programme> items, DateTime t) {
  if (items.isEmpty) return -1;
  int? containing;
  for (var i = 0; i < items.length; i++) {
    final p = items[i];
    if (!p.start.isAfter(t) && p.stop.isAfter(t)) containing = i;
  }
  if (containing != null) return containing;
  var index = 0;
  for (var i = 0; i < items.length; i++) {
    if (!items[i].start.isAfter(t)) {
      index = i;
    } else {
      break;
    }
  }
  return index;
}

/// Painted width of [programme]'s cell. [nextStart] — the following
/// programme's start — visually truncates an overlong entry (bad guide
/// runtimes, e.g. a 13:00–17:00 row overlapping the 14:00 one) so cells never
/// overlap; the detail bar still shows the programme's real times.
double _cellWidth(
  Programme programme,
  DateTime windowStart,
  DateTime windowEnd, {
  DateTime? nextStart,
}) {
  final start = programme.start.isBefore(windowStart)
      ? windowStart
      : programme.start;
  var stop = programme.stop.isAfter(windowEnd) ? windowEnd : programme.stop;
  if (nextStart != null &&
      nextStart.isAfter(start) &&
      nextStart.isBefore(stop)) {
    stop = nextStart;
  }
  final width =
      stop.difference(start).inMinutes * _EpgGridScreenState._pxPerMinute;
  return width < 24 ? 24 : width;
}

/// One programme's paint geometry plus its (constant) semantics label.
///
/// All four values depend only on the row's programme list, the fixed time
/// window and the channel name — none of them change while the row is panned.
/// They used to be recomputed inside the row's `ValueListenableBuilder`, which
/// re-runs at 60 fps for the whole duration of a pan: two `DateTime.difference`
/// calls and a four-part interpolated string per *cell* per *frame*. Computing
/// them once per programme list moves that work off both the pan and cursor
/// paths; the bounded row cache also invalidates translated labels on change.
class _CellLayout {
  final Programme programme;
  final double left;
  final double width;
  final String semanticsLabel;

  const _CellLayout({
    required this.programme,
    required this.left,
    required this.width,
    required this.semanticsLabel,
  });
}

class _ChannelRow extends StatelessWidget {
  /// Subtle full-row lift behind the selected channel (sits over the scaffold
  /// ink; the cells keep their own fills on top).
  static final Color _rowTint = AppColors.panelHi.withValues(alpha: 0.45);

  final Channel channel;
  final List<Programme> programmes;
  final List<_CellLayout> layouts;
  final bool isSelectedRow;
  final bool focused;
  final double fontSize;

  /// The selected programme index on this row, or -1 when it isn't the selected
  /// row. Driven by the grid's [_EpgGridScreenState._selectedCol] so the
  /// highlight matches index stepping exactly (no per-row re-resolution).
  final int selectedIndex;
  final double timelineWidth;
  final double channelColumnWidth;
  final ValueNotifier<double> hOffset;
  final DateTime Function() clock;
  final ValueChanged<Programme> onTapProgramme;
  final VoidCallback onTapChannel;

  const _ChannelRow({
    required this.channel,
    required this.programmes,
    required this.layouts,
    required this.isSelectedRow,
    required this.focused,
    required this.fontSize,
    required this.selectedIndex,
    required this.timelineWidth,
    required this.channelColumnWidth,
    required this.hOffset,
    required this.clock,
    required this.onTapProgramme,
    required this.onTapChannel,
  });

  @override
  Widget build(BuildContext context) {
    // A full-row lift plus an accent bar in the channel column marks the active
    // channel across the whole width — so it's clear *which* row the cursor is on
    // even when the selected cell sits far along the timeline. A ColoredBox (no
    // border/inset) keeps every row's timeline aligned with the hour ruler.
    return ColoredBox(
      color: isSelectedRow ? _rowTint : Colors.transparent,
      child: Row(
        children: [
          SizedBox(
            width: channelColumnWidth,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onTapChannel,
              child: Stack(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    child: Row(
                      children: [
                        if (channel.logo case final logo?
                            when logo.isNotEmpty &&
                                !debugDisableNetworkChannelLogos)
                          ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: CachedNetworkImage(
                              imageUrl: logo,
                              width: 30,
                              height: 30,
                              fit: isTelevision ? BoxFit.contain : BoxFit.cover,
                              memCacheWidth: imageCacheSize(context, 30),
                              errorWidget: (_, url, error) {
                                logImageFailure(error, url);
                                return const SizedBox(width: 30);
                              },
                            ),
                          )
                        else
                          SizedBox(
                            width: 30,
                            child: Icon(
                              Icons.live_tv_rounded,
                              size: 22,
                              color: AppColors.textLo,
                            ),
                          ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            channel.number != null
                                ? '${channel.number} ${channel.name}'
                                : channel.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AppColors.textHi,
                              fontSize: fontSize,
                              height: isTelevision ? 1.2 : null,
                              fontWeight: isSelectedRow
                                  ? FontWeight.w700
                                  : FontWeight.w400,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (isSelectedRow)
                    Positioned(
                      left: 0,
                      top: 8,
                      bottom: 8,
                      child: Container(
                        width: 3,
                        decoration: BoxDecoration(
                          color: focused ? AppColors.accent : AppColors.textLo,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          Expanded(
            child: ClipRect(
              child: ValueListenableBuilder<double>(
                valueListenable: hOffset,
                builder: (context, offset, _) {
                  if (programmes.isEmpty) {
                    return Semantics(
                      label: tr(
                        '{channel}, no programme information, play live',
                        {'channel': channel.name},
                      ),
                      button: true,
                      selected: isSelectedRow,
                      child: GestureDetector(
                        onTap: onTapChannel,
                        behavior: HitTestBehavior.opaque,
                        child: Container(
                          margin: const EdgeInsets.symmetric(vertical: 2),
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          alignment: Alignment.centerLeft,
                          decoration: BoxDecoration(
                            color: isSelectedRow && focused
                                ? _ProgrammeCell._selectedFill
                                : AppColors.panel,
                            borderRadius: BorderRadius.circular(AppRadius.tile),
                            border: Border.all(
                              color: isSelectedRow && focused
                                  ? AppColors.accent
                                  : isTelevision
                                  ? Colors.transparent
                                  : AppColors.line,
                              width: isSelectedRow && focused ? 2 : 1,
                            ),
                          ),
                          child: Text(
                            tr('No programme information'),
                            style: TextStyle(
                              color: AppColors.textLo,
                              fontSize: fontSize,
                            ),
                          ),
                        ),
                      ),
                    );
                  }
                  // Horizontal virtualization: build only the cells whose span
                  // intersects the visible window (+ a buffer). Safe now that
                  // cells aren't focus targets — nothing to strand.
                  const buffer = 240.0;
                  final from = offset - buffer;
                  final to = offset + timelineWidth + buffer;
                  // One clock read per row per frame instead of one per cell —
                  // and it makes currentness consistent across the whole row.
                  final now = clock();
                  final cells = <Widget>[];
                  // The selected cell is appended last so it paints above any
                  // residual overlap (e.g. the 24px minimum width).
                  Widget? selectedCell;
                  for (var i = 0; i < layouts.length; i++) {
                    final layout = layouts[i];
                    final left = layout.left;
                    final width = layout.width;
                    if (left + width < from || left > to) continue;
                    final p = layout.programme;
                    final cell = Positioned(
                      left: left - offset,
                      width: width,
                      top: 2,
                      bottom: 2,
                      child: _ProgrammeCell(
                        programme: p,
                        semanticsLabel: layout.semanticsLabel,
                        selected: i == selectedIndex,
                        focused: focused,
                        fontSize: fontSize,
                        isCurrent: !p.start.isAfter(now) && p.stop.isAfter(now),
                        isPast: !p.stop.isAfter(now),
                        onTap: () => onTapProgramme(p),
                      ),
                    );
                    if (i == selectedIndex) {
                      selectedCell = cell;
                    } else {
                      cells.add(cell);
                    }
                  }
                  if (selectedCell != null) cells.add(selectedCell);
                  return Stack(clipBehavior: Clip.hardEdge, children: cells);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A lightweight programme cell — a plain tappable container with a
/// selection-driven highlight. Deliberately *not* a [FocusableCard]: hundreds
/// are laid out per screen, so it carries no focus node, InkWell, Material or
/// implicit animation. Focus/selection lives in the parent grid.
class _ProgrammeCell extends StatelessWidget {
  final Programme programme;

  /// Precomputed by the row (see [_CellLayout]) — the format is pinned by
  /// `test/epg_grid_test.dart`: `'$title, $channel, $hm to $hm, $n of $total'`.
  final String semanticsLabel;
  final bool selected;
  final bool focused;
  final double fontSize;

  /// Airing state, resolved once per row build from a single clock read rather
  /// than a `DateTime.now()` per cell per frame.
  final bool isCurrent;
  final bool isPast;
  final VoidCallback onTap;

  const _ProgrammeCell({
    required this.programme,
    required this.semanticsLabel,
    required this.selected,
    required this.focused,
    required this.fontSize,
    required this.isCurrent,
    required this.isPast,
    required this.onTap,
  });

  /// Selected cell fill: a solid accent-tinted lift (not just [AppColors.panelHi]),
  /// so the selection cursor reads clearly from across the room and it's obvious
  /// the D-pad is doing something — the reported "looks like nothing's selected".
  static Color get _selectedFill => Color.alphaBlend(
    AppColors.accent.withValues(alpha: isTelevision ? 0.18 : 0.30),
    AppColors.panel,
  );

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticsLabel,
      button: true,
      selected: selected,
      onTap: onTap,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          decoration: BoxDecoration(
            color: selected
                ? (focused ? _selectedFill : AppColors.panelHi)
                : AppColors.panel,
            borderRadius: BorderRadius.circular(AppRadius.tile),
            border: Border.all(
              color: selected && focused
                  ? AppColors.accent
                  : isTelevision
                  ? Colors.transparent
                  : AppColors.line,
              width: selected ? 2 : 1,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                programme.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: selected || isCurrent
                      ? AppColors.textHi
                      : isPast
                      ? AppColors.textLo
                      : AppColors.textLo.withValues(alpha: 0.8),
                  fontSize: fontSize,
                  fontWeight: selected
                      ? FontWeight.w700
                      : isCurrent
                      ? FontWeight.w600
                      : FontWeight.w400,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
