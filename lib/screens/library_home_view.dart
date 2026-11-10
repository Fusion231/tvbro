import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../sources/source.dart';
import '../theme.dart';
import '../widgets/focusable_card.dart';

class LibraryHomeView extends StatelessWidget {
  final ValueChanged<ContentKind> onSelected;
  final Map<ContentKind, FocusNode> focusNodes;
  final ContentKind autofocusKind;
  final VoidCallback onFavoritesSelected;
  final FocusNode favoritesFocusNode;
  final bool autofocusFavorites;
  final Widget? recentlyWatched;

  const LibraryHomeView({
    super.key,
    required this.onSelected,
    required this.focusNodes,
    required this.onFavoritesSelected,
    required this.favoritesFocusNode,
    this.autofocusKind = ContentKind.live,
    this.autofocusFavorites = false,
    this.recentlyWatched,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = MediaQuery.sizeOf(context);
        final wide = isWideLayout(size) || size.width >= 700;
        final padding = wide ? 28.0 : 16.0;
        final tileHeight = constraints.maxHeight < 380 ? 136.0 : 156.0;
        final tiles = [
          _tile(
            id: 'live',
            onTap: () => onSelected(ContentKind.live),
            focusNode: focusNodes[ContentKind.live],
            autofocus: !autofocusFavorites && autofocusKind == ContentKind.live,
            label: tr('TV'),
            icon: Icons.live_tv_rounded,
            tint: AppColors.live,
            wide: wide,
            height: tileHeight,
          ),
          _tile(
            id: 'movie',
            onTap: () => onSelected(ContentKind.movie),
            focusNode: focusNodes[ContentKind.movie],
            autofocus:
                !autofocusFavorites && autofocusKind == ContentKind.movie,
            label: tr('Movies'),
            icon: Icons.movie_outlined,
            tint: AppColors.accentFill,
            wide: wide,
            height: tileHeight,
          ),
          _tile(
            id: 'series',
            onTap: () => onSelected(ContentKind.series),
            focusNode: focusNodes[ContentKind.series],
            autofocus:
                !autofocusFavorites && autofocusKind == ContentKind.series,
            label: tr('Series'),
            icon: Icons.video_library_outlined,
            tint: AppColors.accent,
            wide: wide,
            height: tileHeight,
          ),
          _tile(
            id: 'favorites',
            onTap: onFavoritesSelected,
            focusNode: favoritesFocusNode,
            autofocus: autofocusFavorites,
            label: tr('Favorites'),
            icon: Icons.favorite_outline_rounded,
            tint: AppColors.accent,
            wide: wide,
            height: tileHeight,
          ),
        ];

        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Padding(
              padding: EdgeInsets.all(padding),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1100),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tr('What would you like to watch?'),
                        style: TextStyle(
                          color: AppColors.textHi,
                          fontSize: wide ? 26 : 22,
                          fontWeight: FontWeight.w600,
                          height: 1.2,
                        ),
                      ),
                      const SizedBox(height: 16),
                      FocusTraversalGroup(
                        child: wide
                            ? Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(child: tiles[0]),
                                  const SizedBox(width: 20),
                                  Expanded(child: tiles[1]),
                                  const SizedBox(width: 20),
                                  Expanded(child: tiles[2]),
                                  const SizedBox(width: 20),
                                  Expanded(child: tiles[3]),
                                ],
                              )
                            : Column(
                                children: [
                                  tiles[0],
                                  const SizedBox(height: 12),
                                  tiles[1],
                                  const SizedBox(height: 12),
                                  tiles[2],
                                  const SizedBox(height: 12),
                                  tiles[3],
                                ],
                              ),
                      ),
                      if (recentlyWatched != null) ...[
                        const SizedBox(height: 24),
                        recentlyWatched!,
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _tile({
    required String id,
    required VoidCallback onTap,
    required FocusNode? focusNode,
    required bool autofocus,
    required String label,
    required IconData icon,
    required Color tint,
    required bool wide,
    required double height,
  }) {
    final symbol = Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppRadius.tile),
      ),
      child: Icon(icon, color: AppColors.textHi, size: wide ? 30 : 24),
    );
    final title = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: AppColors.textHi,
        fontSize: wide ? 23 : 20,
        fontWeight: FontWeight.w600,
      ),
    );
    const arrow = Icon(
      Icons.arrow_forward_rounded,
      color: AppColors.textLo,
      size: 24,
    );

    return FocusableCard(
      key: ValueKey('home-$id'),
      focusNode: focusNode,
      autofocus: autofocus,
      semanticsLabel: label,
      onTap: onTap,
      child: Container(
        height: wide ? height : 76,
        padding: EdgeInsets.all(wide ? 16 : 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.tile),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              tint.withValues(alpha: 0.18),
              tint.withValues(alpha: 0.025),
            ],
          ),
        ),
        child: wide
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  symbol,
                  const Spacer(),
                  Row(
                    children: [
                      Expanded(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: title,
                        ),
                      ),
                      arrow,
                    ],
                  ),
                ],
              )
            : Row(
                children: [
                  symbol,
                  const SizedBox(width: 20),
                  Expanded(child: title),
                  const SizedBox(width: 8),
                  arrow,
                ],
              ),
      ),
    );
  }
}
