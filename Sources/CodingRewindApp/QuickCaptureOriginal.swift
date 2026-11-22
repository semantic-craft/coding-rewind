// SPDX-License-Identifier: MIT

import CodingRewindCore
import Foundation
import ImageIO
import PDFKit
import Vision

struct QuickCaptureOriginal: Sendable {
    let original: ClipOriginal
    let derivedText: String?

    nonisolated static func readFile(_ url: URL) throws -> QuickCaptureOriginal {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw RewindError.invalidOriginal }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              (0...Int64(ClipOriginal.maximumBytes)).contains(info.st_size) else {
            throw RewindError.invalidOriginal
        }
        let bytes = try file.read(upToCount: ClipOriginal.maximumBytes + 1) ?? Data()
        guard Int64(bytes.count) == info.st_size else { throw RewindError.invalidOriginal }
        return try prepare(filename: url.lastPathComponent, bytes: bytes)
    }

    nonisolated static func prepare(filename: String, bytes: Data) throws -> QuickCaptureOriginal {
        let original = try ClipOriginal(filename: filename, data: bytes)
        let text: String?
        if bytes.starts(with: Data("%PDF-".utf8)), let document = PDFDocument(data: bytes) {
            let pages = 0..<min(document.pageCount, 12)
            text = pages.compactMap { document.page(at: $0)?.string.map { bounded($0, to: 2400) } }
                .joined(separator: "\n\n")
        } else if !bytes.contains(0), let plainText = String(data: bytes, encoding: .utf8) {
            text = plainText
        } else if let source = CGImageSourceCreateWithData(bytes as CFData, nil) {
            text = recognize(source)
        } else {
            text = nil
        }
        return QuickCaptureOriginal(original: original, derivedText: text.flatMap {
            let result = bounded($0, to: 6200)
            return result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : result
        })
    }

    nonisolated static func bounded(_ text: String, to bytes: Int) -> String {
        var prefix = text.utf8.prefix(max(0, bytes))
        while let next = text.utf8[prefix.endIndex...].first, next & 0xc0 == 0x80, !prefix.isEmpty {
            prefix = prefix.dropLast()
        }
        return String(decoding: prefix, as: UTF8.self)
    }

    private nonisolated static func recognize(_ source: CGImageSource) -> String? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...9000).contains(width), (1...9000).contains(height),
              width * height <= 36_000_000 else { return nil }
        let imageOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2800
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, imageOptions) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US", "zh-Hans"]
        request.usesLanguageCorrection = false
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
            return request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        } catch {
            return nil
        }
    }
}
