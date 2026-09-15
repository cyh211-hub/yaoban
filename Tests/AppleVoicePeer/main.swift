import Foundation
import Darwin
import Security

let pid = getpid()
var code: SecCode?
precondition(SecCodeCopySelf([], &code) == errSecSuccess)
var staticCode: SecStaticCode?
precondition(SecCodeCopyStaticCode(code!, [], &staticCode) == errSecSuccess)
var info: CFDictionary?
precondition(SecCodeCopySigningInformation(staticCode!, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess)
let values = info! as NSDictionary
let hash = (values[kSecCodeInfoUnique] as! Data).map { String(format: "%02x", $0) }.joined()
var path: CFURL?
precondition(SecCodeCopyPath(staticCode!, [], &path) == errSecSuccess)
let expected = ProcessInfo.processInfo.environment["YAOBAN_EXPECTED_PATH"] ?? (path! as URL).standardizedFileURL.path
precondition((path! as URL).standardizedFileURL.path == expected, "process bundle path must match installer manifest convention")
let requirement = "identifier \"local.moss.YaobanPeerTests\" and cdhash H\"\(hash)\""
precondition(approvedVoicePeer(pid: pid, requirementText: requirement, expectedPath: expected))
precondition(!approvedVoicePeer(pid: pid, requirementText: requirement, expectedPath: expected + ".other"))
precondition(!approvedVoicePeer(pid: pid, requirementText: "identifier \"another.app\"", expectedPath: expected))
precondition(!approvedVoicePeer(pid: pid, requirementText: "cdhash H\"0000000000000000000000000000000000000000\"", expectedPath: expected))
precondition(!approvedVoicePeer(pid: 0, requirementText: requirement, expectedPath: expected))
precondition(!approvedVoicePeer(pid: Int32.max, requirementText: requirement, expectedPath: expected))
print("PASS: signed process accepted; wrong path, identifier, hash and PID denied")
