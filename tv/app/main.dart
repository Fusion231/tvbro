import 'package:iptvs/main.dart' as original;
import 'package:iptvs/player/playback_backend.dart';
import 'package:tvbro_tizen_player/tvbro_tizen_player.dart';

Future<void> main() {
  PlaybackBackend.register(
    initialize: () {},
    createPlayer: (configuration) =>
        createTizenPlayer(configuration: configuration),
    ownsPlayer: isTizenPlayer,
    buildVideo: (player, fit, fill) =>
        buildTizenVideo(player, fit: fit, fill: fill),
  );
  return original.main();
}
