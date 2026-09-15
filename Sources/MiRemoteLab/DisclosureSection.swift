import AppKit
final class DisclosureSection: NSStackView {
    private let body: NSView
    private let toggle = NSButton()
    init(title:String,content:NSView) {
        body = content; super.init(frame:.zero)
        orientation = .vertical; alignment = .leading; spacing = 12
        toggle.title = ""; toggle.setButtonType(.onOff); toggle.bezelStyle = .disclosure
        toggle.target = self; toggle.action = #selector(change); toggle.state = .off
        let label = NSTextField(labelWithString:title)
        label.font = .systemFont(ofSize:14,weight:.medium)
        toggle.setAccessibilityLabel(title)
        let header = NSStackView(views:[toggle,label]); header.orientation = .horizontal; header.spacing = 6
        addArrangedSubview(header); addArrangedSubview(body); body.isHidden = true
        body.widthAnchor.constraint(equalTo:widthAnchor).isActive = true
    }
    required init?(coder:NSCoder) { fatalError() }
    @objc private func change() { body.isHidden = toggle.state != .on }
}
