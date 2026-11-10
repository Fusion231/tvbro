import UIKit

/// Lightweight acknowledgement of the cursor while a live zap is settling.
/// Its timer and visibility are controlled by the view controller; this view
/// only prints the parsed Dart snapshot.
final class PlayerZapBannerView: UIView {
  private let identityLabel = UILabel()
  private let detailLabel = UILabel()
  private var renderedState: PlayerZapBannerState?

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    backgroundColor = PlayerColors.panel.withAlphaComponent(0.96)
    layer.cornerRadius = PlayerDimens.menuCorner
    layer.masksToBounds = true
    isUserInteractionEnabled = false
    isHidden = true

    identityLabel.font = PlayerFonts.title
    identityLabel.textColor = PlayerColors.textHi
    identityLabel.numberOfLines = 1
    identityLabel.lineBreakMode = .byTruncatingTail
    detailLabel.font = PlayerFonts.epgMeta
    detailLabel.textColor = PlayerColors.textLo
    detailLabel.numberOfLines = 2
    detailLabel.lineBreakMode = .byTruncatingTail

    let stack = UIStackView(arrangedSubviews: [identityLabel, detailLabel])
    stack.axis = .vertical
    stack.alignment = .fill
    stack.spacing = 4
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      widthAnchor.constraint(lessThanOrEqualToConstant: 440),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("PlayerZapBannerView is created in code, never from a nib")
  }

  func render(_ state: PlayerZapBannerState?, visible: Bool) {
    isHidden = !visible || state == nil
    guard let state, renderedState != state else { return }
    renderedState = state

    var identity = state.identityLabel
    if !state.digits.isEmpty {
      identity += "  ·  \(state.digits)"
    }
    if let message = state.message {
      identity = message
    }
    identityLabel.text = identity

    var lines: [String] = []
    if let now = state.epgNow {
      lines.append("\(clock(now.startMs))–\(clock(now.stopMs))  \(now.title)")
    }
    if let next = state.epgNext {
      lines.append("\(PlayerStrings.text("Next")): \(clock(next.startMs))–\(clock(next.stopMs))  \(next.title)")
    }
    if state.position > 0, state.total > 0 {
      lines.append("\(state.position)/\(state.total)")
    }
    detailLabel.text = lines.joined(separator: "\n")
    detailLabel.isHidden = lines.isEmpty
  }

  private func clock(_ ms: Int64) -> String {
    playerClockHm(ms: ms, locale: PlayerStrings.locale)
  }
}
