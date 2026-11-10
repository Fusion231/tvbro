import UIKit

/// Touch renderer for Dart's windowed `setQuickList` snapshot. It owns no
/// cursor or list rules: a row tap sends the same move/activate pair used by
/// the other native surfaces.
final class PlayerQuickListView: UIView, PlayerTapAbsorbing {
  var onCommand: ((String) -> Void)?

  private let panel = UIView()
  private let header = UIStackView()
  private let titleLabel = UILabel()
  private let countLabel = UILabel()
  private lazy var backButton = PlayerIconButton(
    systemName: "chevron.left",
    accessibilityLabel: PlayerStrings.text("Back"),
    fallbackTitle: PlayerStrings.text("Back")
  ) { [weak self] in self?.onCommand?("zap:back") }
  private lazy var closeButton = PlayerIconButton(
    systemName: "xmark",
    accessibilityLabel: PlayerStrings.text("Close"),
    fallbackTitle: PlayerStrings.text("Close")
  ) { [weak self] in self?.onCommand?("zap:close") }
  private let scrollView = UIScrollView()
  private let rowsStack = UIStackView()
  private let statusLabel = UILabel()
  private var renderedState: PlayerQuickListState?
  private var selectedRow: UIView?
  private var preferredPanelHeight: NSLayoutConstraint?

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    backgroundColor = .clear
    isHidden = true

    panel.translatesAutoresizingMaskIntoConstraints = false
    panel.backgroundColor = PlayerColors.panel
    panel.layer.cornerRadius = PlayerDimens.menuCorner
    panel.layer.masksToBounds = true
    addSubview(panel)

    titleLabel.font = PlayerFonts.panelHeader
    titleLabel.textColor = PlayerColors.textHi
    titleLabel.numberOfLines = 1
    titleLabel.lineBreakMode = .byTruncatingTail
    countLabel.font = PlayerFonts.panelHeader
    countLabel.textColor = PlayerColors.textLo
    countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

    header.axis = .horizontal
    header.alignment = .center
    header.spacing = 8
    header.translatesAutoresizingMaskIntoConstraints = false
    header.addArrangedSubview(backButton)
    header.addArrangedSubview(titleLabel)
    header.addArrangedSubview(countLabel)
    header.addArrangedSubview(closeButton)

    rowsStack.axis = .vertical
    rowsStack.alignment = .fill
    rowsStack.spacing = 2
    rowsStack.translatesAutoresizingMaskIntoConstraints = false

    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.showsVerticalScrollIndicator = true
    scrollView.alwaysBounceVertical = false
    scrollView.addSubview(rowsStack)

    statusLabel.font = PlayerFonts.menuRow
    statusLabel.textColor = PlayerColors.textLo
    statusLabel.numberOfLines = 2
    statusLabel.textAlignment = .center
    statusLabel.isHidden = true
    statusLabel.translatesAutoresizingMaskIntoConstraints = false

    panel.addSubview(header)
    panel.addSubview(scrollView)
    panel.addSubview(statusLabel)
    NSLayoutConstraint.activate([
      panel.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 12),
      panel.bottomAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.bottomAnchor, constant: -12),
      panel.centerXAnchor.constraint(equalTo: safeAreaLayoutGuide.centerXAnchor),
      panel.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
      panel.widthAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.widthAnchor, multiplier: 0.94),

      header.topAnchor.constraint(equalTo: panel.topAnchor, constant: 8),
      header.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
      header.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -8),
      header.heightAnchor.constraint(equalToConstant: 48),

      scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
      scrollView.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
      scrollView.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -8),
      scrollView.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -8),
      scrollView.heightAnchor.constraint(lessThanOrEqualToConstant: 520),
      scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 72),

      rowsStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
      rowsStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
      rowsStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
      rowsStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
      rowsStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),

      statusLabel.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 12),
      statusLabel.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -12),
      statusLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
    ])
    let preferredHeight = panel.heightAnchor.constraint(equalToConstant: 520)
    preferredHeight.priority = UILayoutPriority(750)
    preferredPanelHeight = preferredHeight
    preferredHeight.isActive = true
    let preferredWidth = panel.widthAnchor.constraint(
      equalTo: safeAreaLayoutGuide.widthAnchor,
      multiplier: 0.94
    )
    preferredWidth.priority = UILayoutPriority(750)
    preferredWidth.isActive = true

    let outsideTap = UITapGestureRecognizer(target: self, action: #selector(tappedOutside(_:)))
    outsideTap.cancelsTouchesInView = false
    outsideTap.delegate = self
    addGestureRecognizer(outsideTap)
  }

  required init?(coder: NSCoder) {
    fatalError("PlayerQuickListView is created in code, never from a nib")
  }

  func render(_ state: PlayerQuickListState) {
    isHidden = !state.open
    guard renderedState != state else { return }
    renderedState = state
    titleLabel.text = state.heading
    countLabel.text = state.total > 0
      ? "\(state.selectedIndex + 1)/\(state.total)"
      : ""

    let hasRows = !state.rows.isEmpty
    scrollView.isHidden = !hasRows
    statusLabel.isHidden = hasRows
    statusLabel.text = state.loading
      ? PlayerStrings.text("Loading…")
      : (state.emptyLabel ?? PlayerStrings.text("Nothing here"))
    preferredPanelHeight?.constant = state.rows.isEmpty
      ? 140
      : min(520, CGFloat(68 + state.rows.count * 62))

    for row in rowsStack.arrangedSubviews {
      rowsStack.removeArrangedSubview(row)
      row.removeFromSuperview()
    }
    selectedRow = nil
    for row in state.rows {
      let rowView = PlayerQuickListRowView(row: row, onActivate: { [weak self] in
        guard let self else { return }
        let delta = row.index - state.selectedIndex
        if delta != 0 { self.onCommand?("zap:move:\(delta)") }
        self.onCommand?(row.kind == .category ? "zap:descend" : "zap:activate")
      }, onDescend: { [weak self] in
        guard let self else { return }
        let delta = row.index - state.selectedIndex
        if delta != 0 { self.onCommand?("zap:move:\(delta)") }
        self.onCommand?("zap:descend")
      })
      rowsStack.addArrangedSubview(rowView)
      if row.index == state.selectedIndex { selectedRow = rowView }
    }
    if let selectedRow {
      DispatchQueue.main.async { [weak self, weak selectedRow] in
        guard let self, let selectedRow, self.stateIsOpen else { return }
        self.scrollView.scrollRectToVisible(selectedRow.frame.insetBy(dx: 0, dy: -8), animated: false)
      }
    }
  }

  private var stateIsOpen: Bool { renderedState?.open == true }

  @objc private func tappedOutside(_ recognizer: UITapGestureRecognizer) {
    let point = recognizer.location(in: panel)
    if !panel.bounds.contains(point) { onCommand?("zap:close") }
  }
}

extension PlayerQuickListView: UIGestureRecognizerDelegate {
  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    var candidate: UIView? = touch.view
    while let view = candidate, view !== self {
      if view is UIControl || view === scrollView || view.isDescendant(of: scrollView) { return false }
      candidate = view.superview
    }
    return true
  }
}

private final class PlayerQuickListRowView: UIControl {
  private let row: PlayerQuickListRow
  private let onActivate: () -> Void
  private let onDescend: () -> Void

  init(row: PlayerQuickListRow, onActivate: @escaping () -> Void, onDescend: @escaping () -> Void) {
    self.row = row
    self.onActivate = onActivate
    self.onDescend = onDescend
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    backgroundColor = row.selected ? PlayerColors.accent.withAlphaComponent(0.28) : .clear
    layer.cornerRadius = 8
    isAccessibilityElement = true
    accessibilityLabel = [row.label, row.secondary, row.badge].compactMap { $0 }.joined(separator: ", ")
    accessibilityTraits = row.selected ? [.button, .selected] : [.button]

    let title = UILabel()
    title.text = row.label
    title.font = row.selected ? PlayerFonts.menuRowSelected : PlayerFonts.menuRow
    title.textColor = row.past ? PlayerColors.textLo.withAlphaComponent(0.55) : PlayerColors.textHi
    title.numberOfLines = 1
    title.lineBreakMode = .byTruncatingTail

    let secondary = UILabel()
    secondary.text = row.secondary
    secondary.font = PlayerFonts.epgMeta
    secondary.textColor = PlayerColors.textLo
    secondary.numberOfLines = 1
    secondary.lineBreakMode = .byTruncatingTail
    secondary.isHidden = row.secondary == nil

    let textStack = UIStackView(arrangedSubviews: [title, secondary])
    textStack.axis = .vertical
    textStack.alignment = .fill
    textStack.spacing = 3
    textStack.isUserInteractionEnabled = false
    textStack.translatesAutoresizingMaskIntoConstraints = false

    let detail = UIStackView()
    detail.axis = .horizontal
    detail.alignment = .center
    detail.spacing = 6
    detail.isUserInteractionEnabled = false
    detail.translatesAutoresizingMaskIntoConstraints = false

    if row.playing {
      let playing = UILabel()
      playing.text = "▶"
      playing.font = PlayerFonts.badge
      playing.textColor = PlayerColors.accent
      detail.addArrangedSubview(playing)
    }
    if let badge = row.badge {
      let badgeLabel = UILabel()
      badgeLabel.text = badge
      badgeLabel.font = PlayerFonts.badge
      badgeLabel.textColor = row.live ? PlayerColors.textHi : PlayerColors.accent
      badgeLabel.backgroundColor = row.live ? PlayerColors.live : PlayerColors.panelHi
      badgeLabel.layer.cornerRadius = PlayerDimens.badgeCorner
      badgeLabel.layer.masksToBounds = true
      badgeLabel.textAlignment = .center
      badgeLabel.setContentHuggingPriority(.required, for: .horizontal)
      detail.addArrangedSubview(badgeLabel)
    }
    if row.archive && row.badge == nil {
      let archive = UILabel()
      archive.text = "↶"
      archive.textColor = PlayerColors.textLo
      detail.addArrangedSubview(archive)
    }

    let content = UIStackView(arrangedSubviews: [textStack, detail])
    content.axis = .horizontal
    content.alignment = .center
    content.spacing = 10
    content.isUserInteractionEnabled = false
    content.translatesAutoresizingMaskIntoConstraints = false
    addSubview(content)
    let descendButton = UIButton(type: .system)
    descendButton.setImage(UIImage(systemName: "chevron.right"), for: .normal)
    descendButton.tintColor = PlayerColors.textLo
    descendButton.isHidden = row.kind != .channel
    descendButton.accessibilityLabel = PlayerStrings.text("Open schedule")
    descendButton.translatesAutoresizingMaskIntoConstraints = false
    addSubview(descendButton)
    NSLayoutConstraint.activate([
      heightAnchor.constraint(greaterThanOrEqualToConstant: 60),
      content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      content.trailingAnchor.constraint(lessThanOrEqualTo: descendButton.leadingAnchor, constant: -6),
      content.topAnchor.constraint(equalTo: topAnchor, constant: 6),
      content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
      descendButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      descendButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      descendButton.widthAnchor.constraint(equalToConstant: 36),
      descendButton.heightAnchor.constraint(equalToConstant: 36),
    ])
    addTarget(self, action: #selector(didTap), for: .touchUpInside)
    descendButton.addTarget(self, action: #selector(didDescend), for: .touchUpInside)
  }

  required init?(coder: NSCoder) {
    fatalError("PlayerQuickListRowView is created in code, never from a nib")
  }

  override var isHighlighted: Bool {
    didSet { alpha = isHighlighted ? 0.8 : 1 }
  }

  @objc private func didTap() { onActivate() }
  @objc private func didDescend() { onDescend() }
}
