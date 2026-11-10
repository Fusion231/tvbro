import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show KeyEvent, KeyRepeatEvent;

import '../data/device_class.dart';
import '../sources/source.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';
import '../widgets/routed_focus_node.dart';
import '../widgets/tv_text_field.dart';

const _toolbarControlHeight = 40.0;

/// Content-kind tabs at the top of [ChannelListScreen].
///
/// Focus nodes are supplied by the screen so the Back ladder can retain
/// ownership and jump directly to the selected tab.
class ChannelContentTabs extends StatelessWidget {
  final ContentKind value;
  final ValueChanged<ContentKind> onChanged;
  final Map<ContentKind, FocusNode> focusNodes;
  final bool favoritesSelected;
  final VoidCallback? onFavoritesSelected;
  final FocusNode? favoritesFocusNode;

  const ChannelContentTabs({
    super.key,
    required this.value,
    required this.onChanged,
    required this.focusNodes,
    this.favoritesSelected = false,
    this.onFavoritesSelected,
    this.favoritesFocusNode,
  });

  @override
  Widget build(BuildContext context) {
    return FocusTraversalGroup(
      child: SingleChildScrollView(
        primary: false,
        padding: EdgeInsets.fromLTRB(isTelevision ? 0 : 16, 8, 4, 4),
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _TabChip(
              label: tr('Live'),
              selected: !favoritesSelected && value == ContentKind.live,
              focusNode: focusNodes[ContentKind.live],
              onTap: () => onChanged(ContentKind.live),
            ),
            const SizedBox(width: 4),
            _TabChip(
              label: tr('Movies'),
              selected: !favoritesSelected && value == ContentKind.movie,
              focusNode: focusNodes[ContentKind.movie],
              onTap: () => onChanged(ContentKind.movie),
            ),
            const SizedBox(width: 4),
            _TabChip(
              label: tr('Series'),
              selected: !favoritesSelected && value == ContentKind.series,
              focusNode: focusNodes[ContentKind.series],
              onTap: () => onChanged(ContentKind.series),
            ),
            if (onFavoritesSelected != null) ...[
              const SizedBox(width: 4),
              _TabChip(
                label: tr('Favorites'),
                selected: favoritesSelected,
                focusNode: favoritesFocusNode,
                onTap: onFavoritesSelected!,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TabChip extends StatefulWidget {
  final String label;
  final bool selected;
  final FocusNode? focusNode;
  final VoidCallback onTap;

  const _TabChip({
    required this.label,
    required this.selected,
    required this.focusNode,
    required this.onTap,
  });

  @override
  State<_TabChip> createState() => _TabChipState();
}

class _TabChipState extends State<_TabChip> {
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    widget.focusNode?.addListener(_syncFocus);
  }

  @override
  void didUpdateWidget(covariant _TabChip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode?.removeListener(_syncFocus);
      widget.focusNode?.addListener(_syncFocus);
    }
    _syncFocus();
  }

  @override
  void dispose() {
    widget.focusNode?.removeListener(_syncFocus);
    super.dispose();
  }

  void _syncFocus() {
    _setFocused(widget.focusNode?.hasFocus ?? false);
  }

  void _setFocused(bool focused) {
    if (!mounted || _focused == focused) return;
    setState(() => _focused = focused);
    if (!focused) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_focused) return;
      Scrollable.ensureVisible(
        context,
        alignment: 0.5,
        duration: appMotion(context, const Duration(milliseconds: 180)),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.selected;
    final labelStyle = DefaultTextStyle.of(context).style.merge(
      TextStyle(
        color: active || _focused ? AppColors.textHi : AppColors.textLo,
        fontSize: isTelevision ? 16 : 15,
        fontWeight: active ? FontWeight.w700 : FontWeight.w600,
      ),
    );
    final labelMeasure = TextPainter(
      text: TextSpan(text: widget.label, style: labelStyle),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final tabWidth = labelMeasure.width + 32;
    labelMeasure.dispose();
    return Semantics(
      label: widget.label,
      button: true,
      selected: active,
      onTap: widget.onTap,
      excludeSemantics: true,
      child: FocusableActionDetector(
        focusNode: widget.focusNode,
        onFocusChange: _setFocused,
        mouseCursor: SystemMouseCursors.click,
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap();
              return null;
            },
          ),
        },
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: appMotion(context, const Duration(milliseconds: 120)),
            width: tabWidth,
            height: 40,
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 2),
            decoration: BoxDecoration(
              color: _focused ? AppColors.panelHi : Colors.transparent,
              borderRadius: BorderRadius.circular(AppRadius.tile),
              border: Border.all(
                color: _focused ? AppColors.accent : Colors.transparent,
                width: 2,
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Expanded(
                  child: Center(
                    child: Text(
                      widget.label,
                      style: labelStyle,
                      maxLines: 1,
                      softWrap: false,
                    ),
                  ),
                ),
                Container(
                  height: 2,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: active ? AppColors.accent : Colors.transparent,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Search, category, and per-tab action controls.
class ChannelToolbar extends StatelessWidget {
  final TextEditingController searchController;
  final String query;
  final String hintText;
  final ValueChanged<String> onQueryChanged;
  final VoidCallback onClearQuery;
  final FocusNode? searchCellFocusNode;
  final KeyEventResult Function(FocusNode, KeyEvent)? onSearchCellKeyEvent;
  final Widget? categoryControl;
  final Widget? actionControl;
  final bool singleRow;

  const ChannelToolbar({
    super.key,
    required this.searchController,
    required this.query,
    required this.hintText,
    required this.onQueryChanged,
    required this.onClearQuery,
    this.searchCellFocusNode,
    this.onSearchCellKeyEvent,
    this.categoryControl,
    this.actionControl,
    this.singleRow = false,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = !singleRow && constraints.maxWidth < 620;
        final search = TvTextField(
          controller: searchController,
          hintText: hintText,
          height: _toolbarControlHeight,
          cellFocusNode: searchCellFocusNode,
          onChanged: onQueryChanged,
          textInputAction: TextInputAction.search,
          prefixIcon: const Icon(Icons.search, size: 20),
          showClear: query.isNotEmpty,
          onClear: onClearQuery,
        );
        final trailing = _trailingControls();
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onKeyEvent: onSearchCellKeyEvent,
            child: narrow
                ? Column(
                    children: [
                      search,
                      if (trailing != null) ...[
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: SizedBox(
                            width: double.infinity,
                            child: trailing,
                          ),
                        ),
                      ],
                    ],
                  )
                : Row(
                    children: [
                      Expanded(child: search),
                      if (categoryControl != null) ...[
                        const SizedBox(width: 12),
                        categoryControl!,
                      ],
                      if (actionControl != null) ...[
                        const SizedBox(width: 8),
                        actionControl!,
                      ],
                    ],
                  ),
          ),
        );
      },
    );
  }

  Widget? _trailingControls() {
    if (categoryControl == null) return actionControl;
    if (actionControl == null) return categoryControl;
    return Row(
      children: [
        Expanded(child: categoryControl!),
        const SizedBox(width: 8),
        actionControl!,
      ],
    );
  }
}

class ChannelToolbarIconButton extends StatefulWidget {
  final String tooltip;
  final IconData icon;
  final bool busy;
  final VoidCallback? onPressed;

  const ChannelToolbarIconButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.busy = false,
  });

  @override
  State<ChannelToolbarIconButton> createState() =>
      _ChannelToolbarIconButtonState();
}

class _ChannelToolbarIconButtonState extends State<ChannelToolbarIconButton> {
  final FocusNode _node = FocusNode();
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _node.addListener(_sync);
  }

  void _sync() {
    if (mounted && _focused != _node.hasFocus) {
      setState(() => _focused = _node.hasFocus);
    }
  }

  @override
  void dispose() {
    _node.removeListener(_sync);
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: SizedBox.square(
        dimension: _toolbarControlHeight,
        child: IconButton.filledTonal(
          focusNode: _node,
          style: IconButton.styleFrom(
            backgroundColor: _focused
                ? AppColors.panelHi
                : isTelevision
                ? Colors.transparent
                : AppColors.panel,
            foregroundColor: isTelevision && !_focused
                ? AppColors.textLo
                : AppColors.textHi,
            disabledBackgroundColor: AppColors.panel,
            disabledForegroundColor: AppColors.textLo,
            overlayColor: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.control),
              side: BorderSide(
                color: _focused
                    ? AppColors.accent
                    : isTelevision
                    ? Colors.transparent
                    : AppColors.line,
                width: _focused ? 2 : 1,
              ),
            ),
          ),
          onPressed: widget.onPressed,
          icon: Icon(widget.icon, size: 20),
        ),
      ),
    );
  }
}

class ChannelCategoryDropdown extends StatelessWidget {
  final List<Category> categories;
  final String? value;
  final ValueChanged<String?> onChanged;

  const ChannelCategoryDropdown({
    super.key,
    required this.categories,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return _DropdownFrame(
      builder: (focusNode) => DropdownButton<String?>(
        focusNode: focusNode,
        focusColor: Colors.transparent,
        isDense: true,
        isExpanded: true,
        value: value,
        dropdownColor: AppColors.panelHi,
        borderRadius: BorderRadius.circular(AppRadius.control),
        icon: const Icon(Icons.expand_more, color: AppColors.textLo),
        hint: Text(
          tr('All categories'),
          style: TextStyle(color: AppColors.textLo),
        ),
        items: [
          DropdownMenuItem<String?>(
            value: null,
            child: Text(tr('All categories')),
          ),
          ...categories.map(
            (category) => DropdownMenuItem<String?>(
              value: category.id,
              child: Text(
                category.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
        onChanged: onChanged,
      ),
    );
  }
}

/// Movie categories stay visible while the catalogue below them scrolls.
class MediaCategoryBar extends StatelessWidget {
  final List<MediaCategory> categories;
  final String? value;
  final ValueChanged<String?> onChanged;

  const MediaCategoryBar({
    super.key,
    required this.categories,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: SingleChildScrollView(
        primary: false,
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _MediaCategoryChip(
              key: const ValueKey('media.category.all'),
              id: null,
              label: tr('All categories'),
              selected: value == null,
              onTap: () => onChanged(null),
            ),
            for (final category in categories) ...[
              const SizedBox(width: 8),
              _MediaCategoryChip(
                key: ValueKey('media.category.${category.id}'),
                id: category.id,
                label: category.title,
                selected: value == category.id,
                onTap: () => onChanged(category.id),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MediaCategoryChip extends StatefulWidget {
  final String? id;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _MediaCategoryChip({
    super.key,
    required this.id,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_MediaCategoryChip> createState() => _MediaCategoryChipState();
}

class _MediaCategoryChipState extends State<_MediaCategoryChip> {
  late final _node = RoutedFocusNode('media.category.${widget.id ?? 'all'}');
  bool _focused = false;

  void _onFocusChange(bool focused) {
    if (mounted) setState(() => _focused = focused);
    if (!focused) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_node.hasFocus) return;
      Scrollable.ensureVisible(
        context,
        alignment: 0.5,
        duration: appMotion(context, const Duration(milliseconds: 180)),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: widget.label,
      button: true,
      selected: widget.selected,
      onTap: widget.onTap,
      excludeSemantics: true,
      child: FocusableActionDetector(
        focusNode: _node,
        onFocusChange: _onFocusChange,
        mouseCursor: SystemMouseCursors.click,
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap();
              return null;
            },
          ),
        },
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: appMotion(context, const Duration(milliseconds: 120)),
            constraints: const BoxConstraints(minHeight: 36),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: widget.selected
                  ? AppColors.accent.withValues(alpha: 0.18)
                  : _focused
                  ? AppColors.panelHi
                  : AppColors.panel,
              borderRadius: BorderRadius.circular(AppRadius.control),
              border: Border.all(
                color: _focused
                    ? AppColors.accent
                    : widget.selected
                    ? AppColors.accent.withValues(alpha: 0.45)
                    : AppColors.line,
                width: 2,
              ),
            ),
            child: Text(
              widget.label,
              maxLines: 1,
              softWrap: false,
              style: TextStyle(
                color: widget.selected || _focused
                    ? AppColors.textHi
                    : AppColors.textLo,
                fontSize: 13,
                fontWeight: widget.selected ? FontWeight.w700 : FontWeight.w600,
                height: 1.3,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class MediaCategoryDropdown extends StatelessWidget {
  final List<MediaCategory> categories;
  final String? value;
  final ValueChanged<String?> onChanged;

  const MediaCategoryDropdown({
    super.key,
    required this.categories,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return _DropdownFrame(
      builder: (focusNode) => DropdownButton<String?>(
        focusNode: focusNode,
        focusColor: Colors.transparent,
        isDense: true,
        isExpanded: true,
        value: value,
        dropdownColor: AppColors.panelHi,
        borderRadius: BorderRadius.circular(AppRadius.control),
        icon: const Icon(Icons.expand_more, color: AppColors.textLo),
        hint: Text(
          tr('All categories'),
          style: TextStyle(color: AppColors.textLo),
        ),
        items: [
          DropdownMenuItem<String?>(
            value: null,
            child: Text(tr('All categories')),
          ),
          ...categories.map(
            (category) => DropdownMenuItem<String?>(
              value: category.id,
              child: Text(
                category.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
        onChanged: onChanged,
      ),
    );
  }
}

class _DropdownFrame extends StatefulWidget {
  final Widget Function(FocusNode focusNode) builder;

  const _DropdownFrame({required this.builder});

  @override
  State<_DropdownFrame> createState() => _DropdownFrameState();
}

class _DropdownFrameState extends State<_DropdownFrame> {
  final FocusNode _node = FocusNode();
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _node.addListener(_sync);
  }

  void _sync() {
    if (mounted && _focused != _node.hasFocus) {
      setState(() => _focused = _node.hasFocus);
    }
  }

  @override
  void dispose() {
    _node.removeListener(_sync);
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: _toolbarControlHeight,
      constraints: const BoxConstraints(maxWidth: 220),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: _focused ? AppColors.panelHi : AppColors.panel,
        borderRadius: BorderRadius.circular(AppRadius.control),
        border: Border.all(
          color: _focused ? AppColors.accent : AppColors.line,
          width: _focused ? 2 : 1,
        ),
      ),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: (_, event) => event is KeyRepeatEvent
            ? KeyEventResult.handled
            : KeyEventResult.ignored,
        child: DropdownButtonHideUnderline(child: widget.builder(_node)),
      ),
    );
  }
}
