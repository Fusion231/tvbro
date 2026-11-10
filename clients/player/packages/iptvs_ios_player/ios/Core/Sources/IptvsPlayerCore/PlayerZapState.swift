import Foundation

/// Cursor presentation from Dart's `LiveZapController.bannerPayload()`.
///
/// The native surface never chooses a channel or formats EPG data; it only
/// paints this bounded snapshot and sends commands back over the existing
/// method channel.
public struct PlayerZapBannerState: Equatable, Sendable {
  public let channelNumber: Int?
  public let channelName: String
  public let logoURL: String?
  public let digits: String
  public let message: String?
  public let settling: Bool
  public let position: Int
  public let total: Int
  public let epgNow: PlayerEpgEntry?
  public let epgNext: PlayerEpgEntry?

  public init?(payload: [AnyHashable: Any]) {
    guard let channelName = PlayerOpenRequest.nonBlankString(payload["channelName"]) else {
      return nil
    }
    self.channelName = channelName
    channelNumber = PlayerOpenRequest.int64(payload["channelNumber"]).flatMap(Int.init(exactly:))
    logoURL = PlayerOpenRequest.nonBlankString(payload["logoUrl"])
    digits = PlayerOpenRequest.string(payload["digits"]) ?? ""
    message = PlayerOpenRequest.nonBlankString(payload["message"])
    settling = payload["settling"] as? Bool ?? false
    position = max(0, Int(PlayerOpenRequest.int64(payload["position"]) ?? 0))
    total = max(0, Int(PlayerOpenRequest.int64(payload["total"]) ?? 0))
    epgNow = PlayerOpenRequest.parseEpg(
      payload,
      titleKey: "epgNowTitle",
      startKey: "epgNowStartMs",
      stopKey: "epgNowStopMs",
      descriptionKey: "epgNowDesc"
    )
    epgNext = PlayerOpenRequest.parseEpg(
      payload,
      titleKey: "epgNextTitle",
      startKey: "epgNextStartMs",
      stopKey: "epgNextStopMs",
      descriptionKey: nil
    )
  }

  public var identityLabel: String {
    guard let channelNumber else { return channelName }
    return "\(channelNumber) · \(channelName)"
  }

  public var showsIdentity: Bool {
    channelNumber != nil || !digits.isEmpty || message != nil
  }

  public var outlivesDwell: Bool { !digits.isEmpty || message != nil }
}

public enum PlayerQuickListMode: String, Equatable, Sendable {
  case categories
  case channels
  case schedule
}

public enum PlayerQuickListRowKind: String, Equatable, Sendable {
  case category
  case channel
  case programme
}

/// One of the at most forty rows Dart includes around the current cursor.
public struct PlayerQuickListRow: Equatable, Sendable {
  public let index: Int
  public let id: String
  public let label: String
  public let kind: PlayerQuickListRowKind
  public let secondary: String?
  public let badge: String?
  public let selected: Bool
  public let playing: Bool
  public let archive: Bool
  public let past: Bool
  public let live: Bool

  public init(
    index: Int,
    id: String,
    label: String,
    kind: PlayerQuickListRowKind,
    secondary: String? = nil,
    badge: String? = nil,
    selected: Bool = false,
    playing: Bool = false,
    archive: Bool = false,
    past: Bool = false,
    live: Bool = false
  ) {
    self.index = index
    self.id = id
    self.label = label
    self.kind = kind
    self.secondary = secondary
    self.badge = badge
    self.selected = selected
    self.playing = playing
    self.archive = archive
    self.past = past
    self.live = live
  }

  fileprivate init(payload: Any?, fallbackIndex: Int) {
    guard let map = payload as? [AnyHashable: Any] else {
      self.init(index: fallbackIndex, id: "", label: "", kind: .channel)
      return
    }
    let rawKind = PlayerOpenRequest.string(map["kind"]) ?? "channel"
    self.init(
      index: max(0, Int(PlayerOpenRequest.int64(map["index"]) ?? Int64(fallbackIndex))),
      id: PlayerOpenRequest.string(map["id"]) ?? "",
      label: PlayerOpenRequest.string(map["label"]) ?? "",
      kind: PlayerQuickListRowKind(rawValue: rawKind) ?? .channel,
      secondary: PlayerOpenRequest.nonBlankString(map["secondary"]),
      badge: PlayerOpenRequest.nonBlankString(map["badge"]),
      selected: map["selected"] as? Bool ?? false,
      playing: map["playing"] as? Bool ?? false,
      archive: map["archive"] as? Bool ?? false,
      past: map["past"] as? Bool ?? false,
      live: map["live"] as? Bool ?? false
    )
  }
}

/// Parsed form of Dart's frozen `setQuickList` payload. Malformed rows are
/// retained positionally so a bad element cannot move the highlight onto a
/// different channel.
public struct PlayerQuickListState: Equatable, Sendable {
  public let open: Bool
  public let mode: PlayerQuickListMode
  public let heading: String
  public let rows: [PlayerQuickListRow]
  public let selectedIndex: Int
  public let windowStart: Int
  public let total: Int
  public let loading: Bool
  public let emptyLabel: String?
  public let revision: Int

  public init(payload: [AnyHashable: Any]) {
    open = payload["open"] as? Bool ?? false
    mode = PlayerQuickListMode(rawValue: PlayerOpenRequest.string(payload["mode"]) ?? "")
      ?? .channels
    heading = PlayerOpenRequest.string(payload["heading"]) ?? ""
    let parsedWindowStart = max(0, Int(PlayerOpenRequest.int64(payload["windowStart"]) ?? 0))
    windowStart = parsedWindowStart
    selectedIndex = max(0, Int(PlayerOpenRequest.int64(payload["selectedIndex"]) ?? 0))
    total = max(0, Int(PlayerOpenRequest.int64(payload["total"]) ?? 0))
    loading = payload["loading"] as? Bool ?? false
    emptyLabel = PlayerOpenRequest.nonBlankString(payload["emptyLabel"])
    revision = max(0, Int(PlayerOpenRequest.int64(payload["revision"]) ?? 0))
    let payloadRows = payload["rows"] as? [Any] ?? []
    rows = payloadRows.prefix(40).enumerated().map { offset, row in
      PlayerQuickListRow(payload: row, fallbackIndex: parsedWindowStart + offset)
    }
  }

  public var selectedInWindow: Int? {
    let offset = selectedIndex - windowStart
    return rows.indices.contains(offset) ? offset : nil
  }
}
