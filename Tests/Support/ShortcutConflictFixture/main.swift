// SPDX-License-Identifier: MIT

import Carbon.HIToolbox
import Foundation

alarm(10)
guard CommandLine.arguments.count == 4,
      let keyCode = UInt32(CommandLine.arguments[1]),
      let modifiers = UInt32(CommandLine.arguments[2]),
      let options = UInt32(CommandLine.arguments[3]) else { exit(2) }
var hotKey: EventHotKeyRef?
let status = RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: 0x43524658, id: 1), GetEventDispatcherTarget(), options, &hotKey)
FileHandle.standardOutput.write(Data("\(status)\n".utf8))
guard status == noErr, let hotKey else { exit(1) }
_ = readLine()
UnregisterEventHotKey(hotKey)
