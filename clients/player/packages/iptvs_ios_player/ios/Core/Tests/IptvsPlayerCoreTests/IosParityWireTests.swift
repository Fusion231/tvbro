import XCTest
@testable import IptvsPlayerCore

/// Protects the Dart-to-Swift presentation boundary for live DVR and zap UI.
/// These checks focus on stale positions and rows that could otherwise make
/// the native surface display a different channel or recording than Dart chose.
final class IosParityWireTests: XCTestCase {
  private func openArguments(_ overrides: [String: Any] = [:]) -> [AnyHashable: Any] {
    var map: [AnyHashable: Any] = ["url": "https://example.test/live.m3u8"]
    for (key, value) in overrides { map[key] = value }
    return map
  }

  func testDvrPositionAndFractionStayInsideTheNormalizedWindow() {
    let beforeWindow = PlayerDvrState(
      startMs: -500,
      endMs: 10_000,
      positionMs: -1,
      playbackId: 23
    )
    XCTAssertEqual(beforeWindow.startMs, 0)
    XCTAssertEqual(beforeWindow.positionMs, 0)
    XCTAssertEqual(beforeWindow.fraction, 0)
    XCTAssertEqual(beforeWindow.playbackId, 23)

    let afterWindow = PlayerDvrState(startMs: 20_000, endMs: 30_000, positionMs: 45_000)
    XCTAssertEqual(afterWindow.positionMs, 30_000)
    XCTAssertEqual(afterWindow.fraction, 1)

    let reversedWindow = PlayerDvrState(startMs: 30_000, endMs: 20_000, positionMs: 25_000)
    XCTAssertEqual(reversedWindow.endMs, 30_000)
    XCTAssertEqual(reversedWindow.positionMs, 30_000)
    XCTAssertEqual(reversedWindow.spanMs, 0)
    XCTAssertEqual(reversedWindow.fraction, 0)
  }

  func testDvrPayloadPrefersItsRecordingIdAndFallsBackOnlyWhenAbsent() {
    let current = PlayerDvrState(payload: [
      "dvrAvailable": true,
      "dvrActive": true,
      "dvrStartMs": 1_000,
      "dvrEndMs": 9_000,
      "dvrPositionMs": 5_000,
      "dvrPlaybackId": 41,
      "playbackId": 99,
    ])
    XCTAssertTrue(current.available)
    XCTAssertTrue(current.active)
    XCTAssertEqual(current.positionMs, 5_000)
    XCTAssertEqual(current.fraction, 0.5)
    XCTAssertEqual(current.playbackId, 41)

    let legacy = PlayerDvrState(payload: ["playbackId": 99])
    XCTAssertEqual(legacy.playbackId, 99)
    XCTAssertEqual(PlayerDvrState(payload: ["dvrPlaybackId": -1]).playbackId, 0)
  }

  func testQuickListCursorUsesAbsoluteIndexWithinTheBoundedPayloadWindow() {
    let rows: [Any] = (0..<40).map { offset in
      [
        "index": 800 + offset,
        "id": "channel-\(offset)",
        "label": "Channel \(offset)",
        "kind": "channel",
        // A stale row-local selection must not override the absolute cursor.
        "selected": offset == 1,
      ] as [String: Any]
    }
    let state = PlayerQuickListState(payload: [
      "open": true,
      "mode": "channels",
      "windowStart": 800,
      "selectedIndex": 823,
      "total": 250_000,
      "rows": rows,
    ])

    XCTAssertEqual(state.rows.count, 40)
    XCTAssertEqual(state.total, 250_000)
    XCTAssertEqual(state.selectedInWindow, 23)
    XCTAssertEqual(state.rows[state.selectedInWindow!].id, "channel-23")
    XCTAssertFalse(state.rows[state.selectedInWindow!].selected)
  }

  func testQuickListCapsOversizedPayloadWithoutShiftingAbsoluteCursor() {
    let rows: [Any] = (0..<50).map { offset in
      [
        "index": 300 + offset,
        "id": "channel-\(offset)",
        "label": "Channel \(offset)",
        "kind": "channel",
      ] as [String: Any]
    }
    let state = PlayerQuickListState(payload: [
      "open": true,
      "mode": "channels",
      "windowStart": 300,
      "selectedIndex": 339,
      "total": 50_000,
      "rows": rows,
    ])

    XCTAssertEqual(state.rows.count, 40)
    XCTAssertEqual(state.rows.first?.index, 300)
    XCTAssertEqual(state.rows.last?.index, 339)
    XCTAssertEqual(state.selectedInWindow, 39)
    XCTAssertEqual(state.rows[state.selectedInWindow!].id, "channel-39")
  }

  func testMalformedQuickListRowKeepsItsSlotSoCursorCannotShiftChannels() {
    let state = PlayerQuickListState(payload: [
      "open": true,
      "mode": "channels",
      "windowStart": 50,
      "selectedIndex": 52,
      "total": 5_000,
      "rows": [
        ["index": 50, "id": "first", "label": "First", "kind": "channel"],
        "malformed row",
        ["index": 52, "id": "third", "label": "Third", "kind": "channel"],
      ] as [Any],
    ])

    XCTAssertEqual(state.rows.count, 3)
    XCTAssertEqual(state.rows[1].index, 51)
    XCTAssertEqual(state.rows[1].id, "")
    XCTAssertEqual(state.selectedInWindow, 2)
    XCTAssertEqual(state.rows[state.selectedInWindow!].id, "third")
  }

  func testQuickListDoesNotSelectAChannelOutsideTheSuppliedWindow() {
    let state = PlayerQuickListState(payload: [
      "open": true,
      "mode": "channels",
      "windowStart": 100,
      "selectedIndex": 104,
      "total": 1_000,
      "rows": [["index": 100, "id": "only", "label": "Only"]],
    ])

    XCTAssertEqual(state.rows.count, 1)
    XCTAssertNil(state.selectedInWindow)
  }

  func testZapBannerKeepsChannelIdentityAndBothEpgEntriesTogether() throws {
    let banner = try XCTUnwrap(PlayerZapBannerState(payload: [
      "channelNumber": 12,
      "channelName": "News HD",
      "logoUrl": "https://example.test/news.png",
      "digits": "12",
      "position": 4,
      "total": 80,
      "epgNowTitle": "Headlines",
      "epgNowStartMs": 1_700_000_000_000.0,
      "epgNowStopMs": 1_700_000_600_000.0,
      "epgNowDesc": "Top stories",
      "epgNextTitle": "Weather",
      "epgNextStartMs": 1_700_000_600_000.0,
      "epgNextStopMs": 1_700_001_200_000.0,
    ]))

    XCTAssertEqual(banner.identityLabel, "12 · News HD")
    XCTAssertEqual(banner.position, 4)
    XCTAssertEqual(banner.total, 80)
    XCTAssertEqual(banner.epgNow?.title, "Headlines")
    XCTAssertEqual(banner.epgNow?.description, "Top stories")
    XCTAssertEqual(banner.epgNext?.title, "Weather")
    XCTAssertNil(banner.epgNext?.description)
  }

  func testZapBannerRejectsMissingIdentityAndDropsInvalidEpgRange() {
    XCTAssertNil(PlayerZapBannerState(payload: ["channelName": "  "]))

    let banner = PlayerZapBannerState(payload: [
      "channelName": "Radio",
      "epgNowTitle": "Invalid time",
      "epgNowStartMs": 2_000,
      "epgNowStopMs": 1_000,
    ])
    XCTAssertEqual(banner?.identityLabel, "Radio")
    XCTAssertFalse(banner?.showsIdentity ?? true)
    XCTAssertNil(banner?.epgNow)
  }

  func testOpenRequestCarriesDistinctSessionAndDvrTokens() throws {
    let request = try XCTUnwrap(PlayerOpenRequest(arguments: openArguments([
      "nativeOpenId": NSNumber(value: 71),
      "settingsSession": NSNumber(value: 9),
      "dvrAvailable": true,
      "dvrActive": true,
      "dvrPlaybackId": NSNumber(value: 1234),
      "playbackId": 88,
    ])))
    XCTAssertEqual(request.nativeOpenId, 71)
    XCTAssertEqual(request.settingsSession, 9)
    XCTAssertTrue(request.dvrAvailable)
    XCTAssertTrue(request.dvrActive)
    XCTAssertEqual(request.dvrPlaybackId, 1234)
  }

  func testOpenRequestDoesNotReuseInvalidSessionOrGenericPlaybackTokens() throws {
    let request = try XCTUnwrap(PlayerOpenRequest(arguments: openArguments([
      "nativeOpenId": 0,
      "settingsSession": -1,
      "dvrPlaybackId": -1,
      "playbackId": 88,
    ])))
    XCTAssertNil(request.nativeOpenId)
    XCTAssertEqual(request.settingsSession, 0)
    XCTAssertEqual(request.dvrPlaybackId, 0)
    XCTAssertFalse(request.dvrAvailable)
    XCTAssertFalse(request.dvrActive)
  }
}
