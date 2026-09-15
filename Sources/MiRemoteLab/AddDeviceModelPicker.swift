import AppKit

final class AddDeviceModelPicker: NSObject {
    let models = RemoteModel.catalog.filter(\.supported)
    let chooser = NSPopUpButton(frame:.zero,pullsDown:false)
    let view = NSStackView()
    var model: RemoteModel { models[max(0,chooser.indexOfSelectedItem)] }
    override init() {
        super.init()
        for item in models { chooser.addItem(withTitle:item.title) }
        view.orientation = .vertical; view.alignment = .leading
        view.addArrangedSubview(chooser)
        chooser.widthAnchor.constraint(equalToConstant:360).isActive = true
        view.frame = NSRect(x:0,y:0,width:360,height:32)
    }
}

// Rebuild at menu opening so newly connected devices are selectable without
// recreating a device entry. Retain the existing binding even while offline.
final class BluetoothBindingPicker: NSPopUpButton, NSMenuDelegate {
    let model: RemoteModel
    var current: RemoteBinding
    let candidates: () -> [RemoteBinding]
    var didSelect: ((RemoteBinding) -> Void)?
    init(model: RemoteModel, current: RemoteBinding, candidates: @escaping () -> [RemoteBinding]) {
        self.model = model; self.current = current; self.candidates = candidates
        super.init(frame:.zero,pullsDown:false)
        target = self; action = #selector(chosen)
        menu?.delegate = self
        widthAnchor.constraint(equalToConstant:190).isActive = true
        refreshChoices()
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    func refreshChoices() {
        removeAllItems()
        addItem(withTitle:"未绑定设备"); lastItem?.representedObject = RemoteBinding.unbound(model:model)
        var values = candidates()
        if current.isBound, !values.contains(where: { $0.hidIdentity == current.hidIdentity && $0.peripheralID == current.peripheralID }) {
            values.insert(current,at:0)
        }
        for value in values {
            let name = value.deviceName ?? model.name
            let ambiguous = values.filter { ($0.deviceName ?? model.name) == name }.count > 1
            addItem(withTitle:name + (ambiguous ? " · " + value.hidIdentity.suffix(4) : ""))
            lastItem?.representedObject = value
            if value.hidIdentity == current.hidIdentity, value.peripheralID == current.peripheralID { selectItem(at:numberOfItems - 1) }
        }
        if !current.isBound { selectItem(at:0) }
    }
    func menuWillOpen(_ menu:NSMenu) { refreshChoices() }
    @objc func chosen() {
        guard let binding = selectedItem?.representedObject as? RemoteBinding else { return }
        current = binding; didSelect?(binding)
    }
}
