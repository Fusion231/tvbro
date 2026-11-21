import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  final Widget? status;
  final Widget? recentlyWatched;

  const LibraryHomeView({
    super.key,
    required this.onSelected,
    required this.focusNodes,
    required this.onFavoritesSelected,
    required this.favoritesFocusNode,
    this.autofocusKind = ContentKind.live,
    this.autofocusFavorites = false,
    this.status,
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
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              tr('What would you like to watch?'),
                              style: TextStyle(
                                color: AppColors.textHi,
                                fontSize: wide ? 26 : 22,
                                fontWeight: FontWeight.w600,
                                height: 1.2,
                              ),
                            ),
                          ),
                          if (Platform.isAndroid) const HomeNetworkStatus(),
                        ],
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
                      ?status,
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

class HomeNetworkStatus extends StatelessWidget {
  const HomeNetworkStatus({super.key});

  static final _status = const EventChannel('iptvs/network_status')
      .receiveBroadcastStream()
      .distinct();

  Future<void> _openSettings(BuildContext context) async {
    try {
      final opened = await const MethodChannel('iptvs/device')
          .invokeMethod<bool>('openNetworkSettings');
      if (opened == true) return;
    } on PlatformException {
      // Some TV firmware does not expose its network settings to apps.
    } on MissingPluginException {
      // The home widget can also run without an Android host in previews.
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tr('Open network settings from the Android home screen.'),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => StreamBuilder(
    stream: _status,
    builder: (context, snapshot) {
      final (label, icon) = switch (snapshot.data) {
        'wifi' => ('Wi-Fi', Icons.wifi),
        'ethernet' => ('Ethernet', Icons.lan_outlined),
        'online' => (tr('Online'), Icons.language),
        'offline' => (tr('No internet'), Icons.wifi_off),
        _ => (null, null),
      };
      if (label == null) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsetsDirectional.only(start: 12),
        child: Tooltip(
          message: tr('Network settings'),
          child: TextButton.icon(
            onPressed: () => _openSettings(context),
            style: AppTheme.textButtonTheme.style!.copyWith(
              padding: const WidgetStatePropertyAll(
                EdgeInsets.symmetric(horizontal: 10),
              ),
            ),
            icon: Icon(
              icon,
              size: 16,
              color: snapshot.data == 'offline'
                  ? AppColors.warning
                  : AppColors.success,
            ),
            label: Text(label, style: const TextStyle(fontSize: 12)),
          ),
        ),
      );
    },
  );
}
