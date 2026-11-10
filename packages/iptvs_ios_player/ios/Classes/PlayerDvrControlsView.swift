import UIKit

/// Small native counterpart of the Android/Dart local timeshift and recording
/// controls. Capture policy stays in Dart; this view only sends commands and
/// displays its latest bounded state snapshot.
final class PlayerDvrControlsView: UIView {
  var onCommand: ((String, Int64?) -> Void)?

  private let actionRow = UIStackView()
  private let timeshiftButton: PlayerTextButton
  private let recordButton: PlayerTextButton
  private let goLiveButton: PlayerTextButton
  private let startLabel = UILabel()
  private let endLabel = UILabel()
  private let scrubber = PlayerScrubberView()
  private let seekRow = UIStackView()
  private let messageLabel = UILabel()
  private var state = PlayerDvrState()

  init() {
    timeshiftButton = PlayerTextButton(
      title: PlayerStrings.text("Timeshift"),
      accessibilityLabel: PlayerStrings.text("Start local timeshift")
    ) { }
    recordButton = PlayerTextButton(
      title: PlayerStrings.text("Record"),
      accessibilityLabel: PlayerStrings.text("Toggle recording")
    ) { }
    goLiveButton = PlayerTextButton(
      title: PlayerStrings.text("Go to live"),
      accessibilityLabel: PlayerStrings.text("Go to live")
    ) { }
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false

    timeshiftButton.addTarget(self, action: #selector(startTimeshift), for: .touchUpInside)
    recordButton.addTarget(self, action: #selector(toggleRecording), for: .touchUpInside)
    goLiveButton.addTarget(self, action: #selector(goLive), for: .touchUpInside)

    actionRow.axis = .horizontal
    actionRow.alignment = .center
    actionRow.spacing = PlayerDimens.controlSpacing
    actionRow.addArrangedSubview(timeshiftButton)
    actionRow.addArrangedSubview(recordButton)
    actionRow.addArrangedSubview(goLiveButton)
    actionRow.translatesAutoresizingMaskIntoConstraints = false
    addSubview(actionRow)

    startLabel.font = PlayerFonts.time
    startLabel.textColor = PlayerColors.textLo
    endLabel.font = PlayerFonts.time
    endLabel.textColor = PlayerColors.textLo
    scrubber.onScrub = { [weak self] fraction in
      guard let self, self.state.active, !self.state.busy else { return }
      let target = self.state.startMs + Int64(Double(self.state.spanMs) * fraction)
      self.onCommand?("seek", target)
    }
    seekRow.axis = .horizontal
    seekRow.alignment = .center
    seekRow.spacing = 8
    seekRow.addArrangedSubview(startLabel)
    seekRow.addArrangedSubview(scrubber)
    seekRow.addArrangedSubview(endLabel)
    seekRow.translatesAutoresizingMaskIntoConstraints = false
    addSubview(seekRow)

    messageLabel.font = PlayerFonts.epgMeta
    messageLabel.textColor = PlayerColors.textLo
    messageLabel.numberOfLines = 2
    messageLabel.translatesAutoresizingMaskIntoConstraints = false
    addSubview(messageLabel)

    NSLayoutConstraint.activate([
      actionRow.topAnchor.constraint(equalTo: topAnchor),
      actionRow.leadingAnchor.constraint(equalTo: leadingAnchor),
      actionRow.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
      seekRow.topAnchor.constraint(equalTo: actionRow.bottomAnchor, constant: 8),
      seekRow.leadingAnchor.constraint(equalTo: leadingAnchor),
      seekRow.trailingAnchor.constraint(equalTo: trailingAnchor),
      startLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 42),
      endLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 42),
      scrubber.heightAnchor.constraint(equalToConstant: PlayerDimens.scrubberHeight),
      messageLabel.topAnchor.constraint(equalTo: seekRow.bottomAnchor, constant: 4),
      messageLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
      messageLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
      messageLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("PlayerDvrControlsView is created in code, never from a nib")
  }

  func render(_ state: PlayerDvrState, liveSynced: Bool) {
    self.state = state
    isHidden = !state.available
    timeshiftButton.isHidden = state.active
    recordButton.setTitle(
      PlayerStrings.text(state.recording ? "Stop recording" : "Record"),
      for: .normal
    )
    goLiveButton.isHidden = !state.active
    for button in [timeshiftButton, recordButton, goLiveButton] { button.isEnabled = !state.busy }
    seekRow.isHidden = !state.active
    startLabel.text = PlayerDvrControlsView.formatTime(state.startMs)
    endLabel.text = PlayerDvrControlsView.formatTime(state.endMs)
    scrubber.progress = state.fraction
    scrubber.isEnabled = state.active && !state.busy
    messageLabel.text = state.message
    messageLabel.isHidden = state.message.isEmpty
    // When the capture is behind the edge, the action remains explicitly
    // labelled Go to live; this is separate from the top bar's Live badge.
    goLiveButton.accessibilityHint = liveSynced ? nil : PlayerStrings.text("Return to the live edge")
    setNeedsLayout()
  }

  @objc private func startTimeshift() { onCommand?("timeshift", nil) }
  @objc private func toggleRecording() { onCommand?("record", nil) }
  @objc private func goLive() { onCommand?("goLive", nil) }

  private static func formatTime(_ ms: Int64) -> String {
    let seconds = max(0, ms) / 1_000
    let hours = seconds / 3_600
    let minutes = (seconds / 60) % 60
    let remainder = seconds % 60
    if hours > 0 {
      return "\(hours):\(String(format: "%02lld", minutes)):\(String(format: "%02lld", remainder))"
    }
    return "\(seconds / 60):\(String(format: "%02lld", remainder))"
  }
}
