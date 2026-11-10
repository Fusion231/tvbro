import Foundation

/// Device-local DVR controls mirrored from Dart's `DvrControls.toPayload()`.
/// URLs and provider credentials are deliberately not part of this state.
public struct PlayerDvrState: Equatable, Sendable {
  public let available: Bool
  public let active: Bool
  public let busy: Bool
  public let recording: Bool
  public let startMs: Int64
  public let endMs: Int64
  public let positionMs: Int64
  public let message: String
  public let playbackId: Int64

  public init(
    available: Bool = false,
    active: Bool = false,
    busy: Bool = false,
    recording: Bool = false,
    startMs: Int64 = 0,
    endMs: Int64 = 0,
    positionMs: Int64 = 0,
    message: String = "",
    playbackId: Int64 = 0
  ) {
    self.available = available
    self.active = active
    self.busy = busy
    self.recording = recording
    self.startMs = max(0, startMs)
    self.endMs = max(self.startMs, endMs)
    self.positionMs = min(max(self.startMs, positionMs), max(self.startMs, endMs))
    self.message = message
    self.playbackId = max(0, playbackId)
  }

  public init(payload: [AnyHashable: Any]) {
    self.init(
      available: payload["dvrAvailable"] as? Bool ?? false,
      active: payload["dvrActive"] as? Bool ?? false,
      busy: payload["dvrBusy"] as? Bool ?? false,
      recording: payload["dvrRecording"] as? Bool ?? false,
      startMs: PlayerOpenRequest.int64(payload["dvrStartMs"]) ?? 0,
      endMs: PlayerOpenRequest.int64(payload["dvrEndMs"]) ?? 0,
      positionMs: PlayerOpenRequest.int64(payload["dvrPositionMs"]) ?? 0,
      message: PlayerOpenRequest.string(payload["dvrMessage"]) ?? "",
      playbackId: PlayerOpenRequest.int64(payload["dvrPlaybackId"])
        ?? PlayerOpenRequest.int64(payload["playbackId"])
        ?? 0
    )
  }

  public var spanMs: Int64 { max(0, endMs - startMs) }

  public var fraction: Double {
    guard spanMs > 0 else { return 0 }
    return Double(positionMs - startMs) / Double(spanMs)
  }
}
