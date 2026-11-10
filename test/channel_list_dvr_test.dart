import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/dvr/dvr_service.dart';
import 'package:iptvs/screens/channel_list_screen.dart';

void main() {
  test('a recording matches only its source and channel', () {
    final recording = DvrRecording(
      id: 'recording-1',
      channelName: 'News',
      sourceId: 'source-a',
      channelId: '42',
      startedAt: DateTime.utc(2026, 10, 22),
      status: DvrRecordingStatus.recording,
    );

    expect(
      recordingMatchesChannel(recording, sourceId: 'source-a', channelId: '42'),
      isTrue,
    );
    expect(
      recordingMatchesChannel(recording, sourceId: 'source-b', channelId: '42'),
      isFalse,
      reason: 'provider channel IDs are scoped to their source',
    );
    expect(
      recordingMatchesChannel(recording, sourceId: 'source-a', channelId: '43'),
      isFalse,
    );
    expect(
      recordingMatchesChannel(null, sourceId: 'source-a', channelId: '42'),
      isFalse,
    );
  });
}
