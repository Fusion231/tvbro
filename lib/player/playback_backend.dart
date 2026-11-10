import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';

/// A platform entrypoint may replace only the engine and its video surface.
/// The application still owns stream resolution, playback and its controls.
abstract final class PlaybackBackend {
  static void Function()? _initialize;
  static Player Function(PlayerConfiguration)? _create;
  static bool Function(Player)? _owns;
  static Widget Function(Player, BoxFit, Color)? _video;

  static bool get isCustom => _create != null;

  static void register({
    required void Function() initialize,
    required Player Function(PlayerConfiguration) createPlayer,
    required bool Function(Player) ownsPlayer,
    required Widget Function(Player, BoxFit, Color) buildVideo,
  }) {
    _initialize = initialize;
    _create = createPlayer;
    _owns = ownsPlayer;
    _video = buildVideo;
  }

  static void initialize() {
    final initialize = _initialize;
    if (initialize != null) {
      initialize();
    } else {
      MediaKit.ensureInitialized();
    }
  }

  static Player createPlayer({
    PlayerConfiguration configuration = const PlayerConfiguration(),
  }) => _create?.call(configuration) ?? Player(configuration: configuration);

  static bool usesCustomSurface(Player player) => _owns?.call(player) ?? false;

  static Widget? buildVideo(
    Player player, {
    BoxFit fit = BoxFit.contain,
    Color fill = const Color(0xFF000000),
  }) => usesCustomSurface(player) ? _video!(player, fit, fill) : null;
}
