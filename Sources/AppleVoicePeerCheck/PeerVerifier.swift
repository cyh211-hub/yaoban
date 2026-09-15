import Foundation
import Security

// Shared by the privileged entry point and offline signed-process tests.
func approvedVoicePeer(pid: Int32, requirementText: String, expectedPath: String) -> Bool {
    guard pid > 1 else { return false }
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
          let requirement else { return false }
    var code: SecCode?
    let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
    guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code,
          SecCodeCheckValidity(code, [], requirement) == errSecSuccess else { return false }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
    var path: CFURL?
    guard SecCodeCopyPath(staticCode, [], &path) == errSecSuccess, let path else { return false }
    return (path as URL).standardizedFileURL.path == expectedPath
}
