// GPL-3.0. Authenticate the process connected to the privileged local socket.
import Foundation
import Darwin

let configPath = "/Library/Application Support/YaobanVoice/client.json"
guard getuid() == 0, CommandLine.arguments.count == 2,
      let pid = Int32(CommandLine.arguments[1]), pid > 1 else { exit(2) }
let fd = open(configPath, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
guard fd >= 0 else { exit(2) }
var info = stat()
guard fstat(fd, &info) == 0, info.st_uid == 0, info.st_nlink == 1,
      info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o022 == 0,
      info.st_size > 0, info.st_size <= 4096 else { close(fd); exit(2) }
var buffer = [UInt8](repeating: 0, count: 4097)
let count = read(fd, &buffer, buffer.count); close(fd)
guard count == info.st_size,
      let value = try? JSONSerialization.jsonObject(with: Data(buffer.prefix(count))) as? [String: Any],
      let requirement = value["requirement"] as? String,
      let path = value["bundlePath"] as? String else { exit(2) }
exit(approvedVoicePeer(pid: pid, requirementText: requirement, expectedPath: path) ? 0 : 3)
