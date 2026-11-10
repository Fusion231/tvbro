import XCTest
@testable import IptvsPlayerCore

final class PlayerAspectModeTests: XCTestCase {
  func testAspectLabelsParseAndCycleInSharedOrder() {
    XCTAssertEqual(PlayerAspectMode(label: "Fit"), .fit)
    XCTAssertEqual(PlayerAspectMode(label: "fill"), .fill)
    XCTAssertEqual(PlayerAspectMode(label: "Stretch"), .stretch)
    XCTAssertEqual(PlayerAspectMode(label: "16:9"), .ratio16x9)
    XCTAssertEqual(PlayerAspectMode(label: "4:3"), .ratio4x3)
    XCTAssertNil(PlayerAspectMode(label: "Auto"))

    var mode = PlayerAspectMode.fit
    let expected: [PlayerAspectMode] = [.fit, .fill, .stretch, .ratio16x9, .ratio4x3]
    for value in expected {
      XCTAssertEqual(mode, value)
      mode = mode.next()
    }
    XCTAssertEqual(mode, .fit)
  }

  func testForced16By9IsCenteredAndFittedInPortraitBounds() {
    let rect = playerAspectViewport(width: 390, height: 844, mode: .ratio16x9)
    XCTAssertEqual(rect.x, 0, accuracy: 0.001)
    XCTAssertEqual(rect.y, 312.3125, accuracy: 0.001)
    XCTAssertEqual(rect.width, 390, accuracy: 0.001)
    XCTAssertEqual(rect.height, 219.375, accuracy: 0.001)
    XCTAssertEqual(rect.width / rect.height, 16.0 / 9.0, accuracy: 0.001)
  }

  func testForced4By3IsCenteredAndFittedInWideBounds() {
    let rect = playerAspectViewport(width: 1920, height: 1080, mode: .ratio4x3)
    XCTAssertEqual(rect.x, 240, accuracy: 0.001)
    XCTAssertEqual(rect.y, 0, accuracy: 0.001)
    XCTAssertEqual(rect.width, 1440, accuracy: 0.001)
    XCTAssertEqual(rect.height, 1080, accuracy: 0.001)
    XCTAssertEqual(rect.width / rect.height, 4.0 / 3.0, accuracy: 0.001)
  }

  func testNonRatioModesUseTheWholeVideoSurface() {
    let expected = PlayerAspectRect(x: 0, y: 0, width: 1000, height: 700)
    for mode in [PlayerAspectMode.fit, .fill, .stretch] {
      XCTAssertEqual(playerAspectViewport(width: 1000, height: 700, mode: mode), expected)
    }
  }

  func testInvalidBoundsProduceAnEmptyRect() {
    let empty = PlayerAspectRect(x: 0, y: 0, width: 0, height: 0)
    XCTAssertEqual(playerAspectViewport(width: 0, height: 100, mode: .ratio16x9), empty)
    XCTAssertEqual(playerAspectViewport(width: 100, height: -.infinity, mode: .ratio4x3), empty)
    XCTAssertEqual(playerAspectViewport(width: .nan, height: 100, mode: .fill), empty)
  }
}
