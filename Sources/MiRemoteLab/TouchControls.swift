import AppKit

private final class TouchDocument: NSView { override var isFlipped: Bool { true } }

extension RemoteTouchGesture {
    var title: String {
        switch self {
        case .tap1: return "轻点一次"
        case .tap2: return "轻点两次"
        case .tap3: return "轻点三次"
        case .swipeUp: return "向上滑动"
        case .swipeDown: return "向下滑动"
        case .swipeLeft: return "向左滑动"
        case .swipeRight: return "向右滑动"
        }
    }
}

extension LabApp {
    func makeTouchControls() -> NSView {
        touchModePopup.removeAllItems()
        for mode in RemoteTouchSettings.Mode.allCases {
            touchModePopup.addItem(withTitle:mode.title); touchModePopup.lastItem?.representedObject = mode.rawValue
        }
        touchModePopup.target = self; touchModePopup.action = #selector(touchModeChanged)
        touchModePopup.widthAnchor.constraint(equalToConstant:210).isActive = true
        touchModePopup.setAccessibilityLabel("苹果圆盘操作")
        touchSpeedSlider.target = self; touchSpeedSlider.action = #selector(touchSpeedChanged)
        touchSpeedSlider.isContinuous = false
        touchSpeedSlider.widthAnchor.constraint(equalToConstant:140).isActive = true
        touchSpeedSlider.setAccessibilityLabel("圆盘速度")
        touchSpeedLabel.font = .monospacedDigitSystemFont(ofSize:12,weight:.regular)
        touchSpeedLabel.widthAnchor.constraint(equalToConstant:58).isActive = true
        touchStatusLabel.font = .systemFont(ofSize:12); touchStatusLabel.textColor = .secondaryLabelColor
        let acceleration = NSButton(checkboxWithTitle:"加速",target:self,action:#selector(touchAccelerationChanged(_:)))
        acceleration.identifier = NSUserInterfaceItemIdentifier("touchAcceleration")
        touchSpeedSlider.toolTip = "加速后的输出也不会超过所设速度。"
        let modeRow = horizontal([label("触控模式",weight:.medium),touchModePopup,spring(),touchStatusLabel])
        let speedRow = horizontal([label("速度上限",weight:.medium),touchSpeedSlider,touchSpeedLabel,acceleration,spring()])
        let general = card([modeRow,speedRow,
            touchParameterRow("外环范围",identifier:"touchRingRadius",min:0.2,max:0.45,value:0.35),
            label("外环顺时针上滚，逆时针下滚；内部移动鼠标。落指确定区域，抬手后重新判断。",size:12,secondary:true)])
        touchGesturePopups.removeAll()
        let taps = card([label("表面轻点",size:17,weight:.semibold)] +
            [RemoteTouchGesture.tap1,.tap2,.tap3].map { touchGestureRow($0) } +
            [touchParameterRow("连点间隔",identifier:"touchTapInterval",min:0.2,max:0.6,value:0.3),
             label("轻点与实体按键独立；多次轻点只执行对应的映射。",size:12,secondary:true)])
        let swipes = card([label("四向滑动",size:17,weight:.semibold)] +
            [RemoteTouchGesture.swipeUp,.swipeDown,.swipeLeft,.swipeRight].map { touchGestureRow($0) } +
            [touchParameterRow("触发距离",identifier:"touchSwipeDistance",min:0.1,max:0.5,value:0.17)])
        let stack = vertical([general,taps,swipes],spacing:16)
        let document = TouchDocument(), scroll = NSScrollView()
        document.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(stack)
        scroll.documentView = document; scroll.drawsBackground = false
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo:scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo:document.topAnchor),
            stack.bottomAnchor.constraint(equalTo:document.bottomAnchor,constant:-12),
            stack.leadingAnchor.constraint(equalTo:document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo:document.trailingAnchor,constant:-8)])
        for item in [general,taps,swipes] { item.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive = true }
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:250).isActive = true
        scroll.setContentHuggingPriority(.defaultLow,for:.vertical)
        touchControls = scroll; return scroll
    }
    private func touchGestureRow(_ gesture: RemoteTouchGesture) -> NSView {
        let name = label(gesture.title,weight:.medium)
        name.widthAnchor.constraint(equalToConstant:100).isActive = true
        let popup = NSPopUpButton(frame:.zero,pullsDown:false)
        popup.tag = RemoteTouchGesture.allCases.firstIndex(of:gesture)!
        popup.target = self; popup.action = #selector(touchMappingSelected(_:))
        popup.setAccessibilityLabel(gesture.title + "映射")
        popup.widthAnchor.constraint(greaterThanOrEqualToConstant:310).isActive = true
        popup.setContentHuggingPriority(.defaultLow,for:.horizontal)
        touchGesturePopups[gesture] = popup
        return horizontal([name,popup,spring()])
    }
    private func touchParameterRow(_ title:String,identifier:String,min:Double,max:Double,value:Double) -> NSView {
        let name = label(title,weight:.medium); name.widthAnchor.constraint(equalToConstant:100).isActive = true
        let slider = NSSlider(value:value,minValue:min,maxValue:max,target:self,action:#selector(touchParameterChanged(_:)))
        slider.identifier = NSUserInterfaceItemIdentifier(identifier); slider.isContinuous = false
        slider.setAccessibilityLabel(title); slider.widthAnchor.constraint(equalToConstant:140).isActive = true
        let valueLabel = label(""); valueLabel.identifier = NSUserInterfaceItemIdentifier(identifier + "Value")
        valueLabel.font = .monospacedDigitSystemFont(ofSize:12,weight:.regular)
        return horizontal([name,slider,valueLabel,spring()])
    }
    private func touchSubview(_ identifier:String,in view:NSView?) -> NSView? {
        guard let view else { return nil }
        if view.identifier?.rawValue == identifier { return view }
        for child in view.subviews { if let found = touchSubview(identifier,in:child) { return found } }
        return nil
    }
    func refreshTouchControls() {
        let supported = selectedDevice?.binding.model == .apple, settings = configuration.touch
        touchControls?.isHidden = !supported
        touchModePopup.selectItem(at:RemoteTouchSettings.Mode.allCases.firstIndex(of:settings.mode) ?? 0)
        touchModePopup.isEnabled = supported
        touchSpeedSlider.doubleValue = settings.speed
        let usesMotion = settings.mode != .off && settings.mode != .swipe
        touchSpeedSlider.isEnabled = supported && usesMotion
        touchSpeedLabel.stringValue = String(format:"%.1f 级",settings.speed)
        if let acceleration = touchSubview("touchAcceleration",in:touchControls) as? NSButton {
            acceleration.state = settings.acceleration ? .on : .off; acceleration.isEnabled = supported && usesMotion
        }
        for (identifier,value,enabled,text) in [
            ("touchTapInterval",settings.tapInterval,settings.mode != .off,String(format:"%.2f 秒",settings.tapInterval)),
            ("touchRingRadius",settings.ringStartRadius,settings.mode == .hybrid,String(format:"半径外侧 %.0f%%",(0.5-settings.ringStartRadius)*200)),
            ("touchSwipeDistance",settings.swipeDistance,settings.mode == .swipe,String(format:"直径的 %.0f%%",settings.swipeDistance*100))] {
            if let slider = touchSubview(identifier,in:touchControls) as? NSSlider { slider.doubleValue = value; slider.isEnabled = supported && enabled }
            (touchSubview(identifier+"Value",in:touchControls) as? NSTextField)?.stringValue = text
        }
        for (gesture,popup) in touchGesturePopups {
            let keys = settings.binding(for:gesture) ?? gesture.legacySource.flatMap { configuration.bindings[$0] } ?? []
            let capturing = recordingTouchGesture == gesture
            popup.removeAllItems()
            if capturing || !keys.isEmpty {
                popup.addItem(withTitle:capturing ? recordingPreview : KeyboardKey.compactDescription(keys))
                popup.lastItem?.representedObject = "current"
            }
            popup.addItem(withTitle:"无映射"); popup.lastItem?.representedObject = "none"
            popup.addItem(withTitle:"创建映射…"); popup.lastItem?.representedObject = "create"
            popup.selectItem(at:0)
            popup.isEnabled = supported && settings.mode != .off && (gesture.tapCount != nil || settings.mode == .swipe)
        }
        touchStatusLabel.stringValue = isPreview ? "界面演示" : settings.mode == .off ? "已关闭" : selectedRuntime?.touch.status ?? "等待设备"
    }
    @objc func touchMappingSelected(_ sender:NSPopUpButton) {
        guard RemoteTouchGesture.allCases.indices.contains(sender.tag), binding?.model == .apple else { return }
        let gesture = RemoteTouchGesture.allCases[sender.tag], action = sender.selectedItem?.representedObject as? String
        sender.selectItem(at:0)
        if action == "none" {
            recorder.cancel(); endRecording(message:"")
            _ = editDeviceConfiguration { $0.touch.setBinding([],for:gesture) }
        } else if action == "create" { beginTouchMapping(gesture) }
    }
    func beginTouchMapping(_ gesture:RemoteTouchGesture) {
        guard !isPreview, let deviceID = selectedDevice?.id, binding?.model == .apple, physicalKeys.isEmpty else { return }
        recorder.cancel(); calibration.stop()
        for runtime in runtimes.values { runtime.release(blocking:runtime.physicalKeys) }
        recordingSource = nil; recordingLongPress = false; recordingTouchGesture = gesture
        let ticket = UUID(); recordingTicket = ticket
        recordingPreview = "等待输入…"; window.makeFirstResponder(nil); refreshTouchControls()
        DispatchQueue.main.asyncAfter(deadline:.now()+0.15) { [weak self] in
            guard let self, self.recordingTicket == ticket, self.recordingTouchGesture == gesture else { return }
            guard self.window.isKeyWindow, self.selectedDevice?.id == deviceID, self.physicalKeys.isEmpty else {
                self.endRecording(message:"录入已结束，原设置保留。"); return
            }
            self.recorder.begin(in:self.window)
        }
    }
    @objc func touchModeChanged() {
        guard binding?.model == .apple, let raw = touchModePopup.selectedItem?.representedObject as? String,
              let mode = RemoteTouchSettings.Mode(rawValue:raw) else { return }
        _ = editDeviceConfiguration { $0.touch.mode = mode }; refreshTouchControls()
    }
    @objc func touchSpeedChanged() {
        let speed = (touchSpeedSlider.doubleValue * 10).rounded() / 10
        _ = editDeviceConfiguration { $0.touch.speed = speed }; refreshTouchControls()
    }
    @objc func touchAccelerationChanged(_ sender:NSButton) {
        guard binding?.model == .apple else { return }
        _ = editDeviceConfiguration { $0.touch.acceleration = sender.state == .on }; refreshTouchControls()
    }
    @objc func touchParameterChanged(_ sender:NSSlider) {
        let value = (sender.doubleValue*100).rounded()/100
        _ = editDeviceConfiguration {
            switch sender.identifier?.rawValue {
            case "touchTapInterval": $0.touch.tapInterval = value
            case "touchRingRadius": $0.touch.ringStartRadius = value
            case "touchSwipeDistance": $0.touch.swipeDistance = value
            default: break
            }
        }
        refreshTouchControls()
    }
}
