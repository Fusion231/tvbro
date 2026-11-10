import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show setEquals;

import '../data/library_repository.dart';
import '../data/net.dart';
import '../data/epg_models.dart';
import '../sources/source.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';
import '../widgets/focusable_card.dart';
import 'media_tab_view.dart';

/// Local search within the active content tab, across its visible categories.
class GlobalSearchView extends StatefulWidget {
  final LibraryRepository repo;
  final ContentKind kind;
  final String query;
  final List<Channel> channels;
  final bool channelsLoading;
  final String? channelsError;
  final Set<String> hiddenMovieCategories;
  final Set<String> hiddenSeriesCategories;
  final bool Function(MediaItem) isMediaAllowed;
  final ValueChanged<Channel> onPlayChannel;
  final ValueChanged<MediaItem> onOpenMedia;
  final Set<String>? programmeChannelIds;
  final ValueChanged<ProgrammeSearchResult>? onOpenProgramme;
  final Map<String, String> channelNames;

  const GlobalSearchView({
    super.key,
    required this.repo,
    required this.kind,
    required this.query,
    required this.channels,
    required this.channelsLoading,
    required this.channelsError,
    required this.hiddenMovieCategories,
    required this.hiddenSeriesCategories,
    required this.isMediaAllowed,
    required this.onPlayChannel,
    required this.onOpenMedia,
    this.programmeChannelIds,
    this.onOpenProgramme,
    this.channelNames = const {},
  });

  @override
  State<GlobalSearchView> createState() => _GlobalSearchViewState();
}

class _GlobalSearchViewState extends State<GlobalSearchView> {
  final _scrollController = ScrollController();
  final _results = <ContentKind, List<MediaItem>>{};
  final _visibleResults = <ContentKind, List<MediaItem>>{};
  final _errors = <ContentKind, String>{};
  Timer? _debounce;
  int _generation = 0;
  int _programmeRequest = 0;
  List<ProgrammeSearchResult>? _programmes;
  String? _programmeError;
  StreamSubscription<String>? _guideChanged;

  bool get _searchesProgrammes =>
      widget.kind == ContentKind.live && widget.onOpenProgramme != null;

  @override
  void initState() {
    super.initState();
    _scheduleSearch();
    _watchGuide();
  }

  @override
  void didUpdateWidget(covariant GlobalSearchView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The parent's permission callback can retain its identity while its
    // captured parental-control state changes. Recheck on parent updates.
    _visibleResults.clear();
    if (oldWidget.query.trim() != widget.query.trim() ||
        oldWidget.repo != widget.repo ||
        oldWidget.kind != widget.kind ||
        (widget.kind == ContentKind.live &&
            (!setEquals(
                  oldWidget.programmeChannelIds,
                  widget.programmeChannelIds,
                ) ||
                (oldWidget.onOpenProgramme == null) !=
                    (widget.onOpenProgramme == null)))) {
      _scheduleSearch();
      if (_scrollController.hasClients) _scrollController.jumpTo(0);
    }
    if (oldWidget.repo != widget.repo ||
        oldWidget.kind != widget.kind ||
        (oldWidget.onOpenProgramme == null) !=
            (widget.onOpenProgramme == null)) {
      _watchGuide();
    }
  }

  void _watchGuide() {
    unawaited(_guideChanged?.cancel());
    _guideChanged = null;
    if (!_searchesProgrammes) return;
    _guideChanged = widget.repo.db.epgChanged.listen((sourceId) {
      if (mounted &&
          _searchesProgrammes &&
          sourceId == widget.repo.source.id &&
          widget.query.trim().isNotEmpty &&
          _debounce?.isActive != true) {
        unawaited(_searchProgrammes(_generation));
      }
    });
  }

  void _scheduleSearch() {
    _debounce?.cancel();
    final generation = ++_generation;
    _results.clear();
    _visibleResults.clear();
    _errors.clear();
    _programmes = null;
    _programmeError = null;
    if (widget.query.trim().isEmpty) {
      _results[widget.kind] = const [];
      _programmes = const [];
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 800), () {
      if (widget.kind == ContentKind.movie ||
          widget.kind == ContentKind.series) {
        unawaited(_search(widget.kind, generation));
      }
      if (_searchesProgrammes) {
        unawaited(_searchProgrammes(generation));
      }
    });
  }

  Future<void> _searchProgrammes(int generation) async {
    final request = ++_programmeRequest;
    try {
      final results = await widget.repo.searchProgrammes(
        widget.query.trim(),
        allowedChannelIds: widget.programmeChannelIds,
        from: DateTime.now().subtract(const Duration(days: 7)),
        to: DateTime.now().add(const Duration(days: 14)),
      );
      if (!mounted ||
          generation != _generation ||
          request != _programmeRequest) {
        return;
      }
      setState(() {
        _programmes = results;
        _programmeError = null;
      });
    } catch (_) {
      if (!mounted ||
          generation != _generation ||
          request != _programmeRequest) {
        return;
      }
      setState(
        () => _programmeError = tr('Could not search the programme guide.'),
      );
    }
  }

  Future<void> _search(ContentKind kind, int generation) async {
    try {
      final items = await widget.repo.searchMedia(kind, widget.query.trim());
      if (!mounted || generation != _generation) return;
      setState(() {
        _results[kind] = items;
        _visibleResults.remove(kind);
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() => _errors[kind] = sourceLoadErrorMessage(error));
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    unawaited(_guideChanged?.cancel());
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      controller: _scrollController,
      slivers: [
        if (widget.kind == ContentKind.live) ...[
          _heading(tr('Channels'), widget.channelsLoading),
          if (widget.channelsError != null)
            _message(widget.channelsError!)
          else if (!widget.channelsLoading && widget.channels.isEmpty)
            _message(tr('No channels found')),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverList.builder(
              itemCount: widget.channels.length,
              itemBuilder: (context, index) {
                final channel = widget.channels[index];
                return _result(
                  key: 'search.live.${channel.id}',
                  title: channel.name,
                  icon: Icons.live_tv_rounded,
                  onTap: () => widget.onPlayChannel(channel),
                );
              },
            ),
          ),
          if (_searchesProgrammes) ..._programmeSection(),
        ] else
          ..._mediaSection(widget.kind),
        const SliverToBoxAdapter(child: SizedBox(height: 16)),
      ],
    );
  }

  List<Widget> _programmeSection() => [
    _heading(tr('Programmes'), _programmes == null && _programmeError == null),
    if (_programmeError != null) ...[
      _message(_programmeError!),
      SliverToBoxAdapter(
        child: TextButton(
          onPressed: () {
            setState(() => _programmeError = null);
            unawaited(_searchProgrammes(_generation));
          },
          child: Text(tr('Retry programme search')),
        ),
      ),
    ] else if (_programmes != null && _programmes!.isEmpty)
      _message(tr('No programmes found in the cached guide')),
    SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      sliver: SliverList.builder(
        itemCount: _programmes?.length ?? 0,
        itemBuilder: (context, index) {
          final result = _programmes![index];
          final start = result.programme.start.toLocal();
          String two(int value) => value.toString().padLeft(2, '0');
          return _result(
            key:
                'search.programme.${result.channel.id}.${start.millisecondsSinceEpoch}',
            title:
                '${result.programme.title}\n${widget.channelNames[result.channel.id] ?? result.channel.name} · '
                '${two(start.day)}.${two(start.month)} ${two(start.hour)}:${two(start.minute)}',
            icon: Icons.event_outlined,
            onTap: () => widget.onOpenProgramme?.call(result),
          );
        },
      ),
    ),
  ];

  List<Widget> _mediaSection(ContentKind kind) {
    final hidden = kind == ContentKind.movie
        ? widget.hiddenMovieCategories
        : widget.hiddenSeriesCategories;
    // Cache category and permission filtering until data or parent state changes.
    final items = _visibleResults.putIfAbsent(
      kind,
      () => (_results[kind] ?? const <MediaItem>[])
          .where(
            (item) =>
                !hidden.contains(item.categoryId) &&
                widget.isMediaAllowed(item),
          )
          .toList(),
    );
    final error = _errors[kind];
    final loading = !_results.containsKey(kind) && error == null;
    final windowSize = MediaQuery.sizeOf(context);
    final useGrid =
        windowSize.width >= kMediaGridMinWidth &&
        windowSize.height >= kMediaGridMinHeight;
    final grid = MediaGridMetrics.forSize(windowSize);
    final textBudget = mediaTileTextBudget(context);
    Widget mediaCard(int index) {
      final item = items[index];
      final label = 'search.${kind.name}.${item.id}';
      if (useGrid) {
        return MediaGridTile(
          key: ValueKey(label),
          debugLabel: label,
          item: item,
          favorite: false,
          position: index + 1,
          total: items.length,
          autofocus: false,
          textBudget: textBudget,
          onTap: () => widget.onOpenMedia(item),
        );
      }
      return MediaListTile(
        key: ValueKey(label),
        debugLabel: label,
        item: item,
        favorite: false,
        position: index + 1,
        total: items.length,
        autofocus: false,
        onTap: () => widget.onOpenMedia(item),
      );
    }

    return [
      _heading(
        kind == ContentKind.movie ? tr('Movies') : tr('Series'),
        loading,
      ),
      if (error != null)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(error, style: const TextStyle(color: AppColors.textLo)),
                TextButton(
                  onPressed: () {
                    setState(() => _errors.remove(kind));
                    unawaited(_search(kind, _generation));
                  },
                  child: Text(tr('Retry')),
                ),
              ],
            ),
          ),
        )
      else if (!loading && items.isEmpty)
        _message(
          kind == ContentKind.movie
              ? tr('No movies found')
              : tr('No series found'),
        ),
      if (useGrid)
        SliverLayoutBuilder(
          builder: (context, constraints) => SliverPadding(
            padding: grid.padding,
            sliver: SliverGrid.builder(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: grid.columns,
                crossAxisSpacing: grid.crossAxisSpacing,
                mainAxisSpacing: grid.mainAxisSpacing,
                childAspectRatio: grid.childAspectRatio(
                  tileWidth: grid.tileWidth(constraints.crossAxisExtent),
                  textBudget: textBudget,
                ),
              ),
              itemCount: items.length,
              itemBuilder: (context, index) => mediaCard(index),
            ),
          ),
        )
      else
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverList.builder(
            itemCount: items.length,
            itemBuilder: (context, index) => mediaCard(index),
          ),
        ),
    ];
  }

  Widget _heading(String title, bool loading) => SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Row(
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          if (loading) ...[
            const SizedBox(width: 12),
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ],
        ],
      ),
    ),
  );

  Widget _message(String text) => SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Text(text, style: const TextStyle(color: AppColors.textLo)),
    ),
  );

  Widget _result({
    required String key,
    required String title,
    required IconData icon,
    required VoidCallback onTap,
  }) => FocusableCard(
    key: ValueKey(key),
    debugLabel: key,
    semanticsLabel: title,
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              color: AppColors.panelHi,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: AppColors.accent),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 8),
          const Icon(Icons.chevron_right, color: AppColors.textLo),
        ],
      ),
    ),
  );
}
