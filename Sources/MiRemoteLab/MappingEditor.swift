import AppKit

extension LabApp {
    @objc func mappingSelected(_ sender:NSPopUpButton) {
        let source = UInt16(sender.tag & 0xFFFF), long = sender.tag > 0xFFFF
        let action = sender.selectedItem?.representedObject as? String
        sender.selectItem(at:0)
        if recordingSource != nil && !recorder.isActive { endRecording(message:"录入已结束，原设置保留。") }
        if action == "none" { recorder.cancel(); _ = changeBinding([],for:source,longPress:long); table.reloadData() }
        else if action == "create" { beginMapping(source:source,longPress:long) }
    }
    func beginMapping(source:UInt16,longPress:Bool) {
        guard !isPreview, let deviceID = selectedDevice?.id, physicalKeys.isEmpty else { return }
        recorder.cancel(); calibration.stop()
        for runtime in runtimes.values { runtime.release(blocking:runtime.physicalKeys) }
        recordingTouchGesture = nil; recordingSource = source; recordingLongPress = longPress; selectedBindingIsLong = longPress
        let ticket = UUID(); recordingTicket = ticket
        recordingPreview = "等待输入…"; window.makeFirstResponder(table)
        reloadRecordingRow()
        // Let the menu selection's mouse release finish before accepting a chord.
        DispatchQueue.main.asyncAfter(deadline:.now()+0.15) { [weak self] in
            guard let self, self.recordingTicket == ticket, self.recordingSource == source,
                  self.recordingLongPress == longPress else { return }
            guard self.window.isKeyWindow, self.selectedDevice?.id == deviceID, self.physicalKeys.isEmpty else {
                self.endRecording(message:"录入已结束，原设置保留。"); return
            }
            self.recorder.begin(in:self.window)
        }
    }
}
