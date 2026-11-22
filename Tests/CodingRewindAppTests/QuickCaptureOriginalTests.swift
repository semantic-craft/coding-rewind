// SPDX-License-Identifier: MIT

@testable import CodingRewindApp
import Foundation
import Testing

struct QuickCaptureOriginalTests {
    @Test("A UTF-8 original keeps whitespace in the file and searchable text")
    func textOriginalPreservesWhitespace() throws {
        let text = "命令输出\n\n    retry worker  \n"
        let bytes = Data(text.utf8)
        let prepared = try QuickCaptureOriginal.prepare(filename: "trace.log", bytes: bytes)
        #expect(prepared.original.data == bytes)
        #expect(prepared.derivedText == text)
        #expect(QuickCaptureOriginal.bounded("a文", to: 3) == "a")
    }
}
