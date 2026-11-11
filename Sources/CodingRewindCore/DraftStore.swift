// SPDX-License-Identifier: MIT

import Foundation

public struct DraftDocument: Identifiable, Equatable, Hashable, Codable, Sendable {
    public let id: DraftID
    public let fileURL: URL
    public var title: String
    public var pinnedClipIDs: [ClipID]
    public var markdownBody: String
    public var updatedAt: Date

    public init(
        id: DraftID,
        fileURL: URL,
        title: String,
        pinnedClipIDs: [ClipID],
        markdownBody: String,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.fileURL = fileURL
        self.title = title
        self.pinnedClipIDs = pinnedClipIDs
        self.markdownBody = markdownBody
        self.updatedAt = updatedAt
    }
}

public actor DraftStore {
    public static let headerPrefix = "<!-- coding-rewind-clips: "
    public static let headerSuffix = " -->"

    public let directoryURL: URL

    public init(directoryURL: URL) throws {
        let resolved = directoryURL.standardizedFileURL
        try FileManager.default.createDirectory(at: resolved, withIntermediateDirectories: true)
        self.directoryURL = resolved
    }

    public func listDrafts() throws -> [DraftDocument] {
        let fm = FileManager.default
        let urls = try fm.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        var documents: [DraftDocument] = []
        for url in urls where url.pathExtension.lowercased() == "md" {
            let stem = url.deletingPathExtension().lastPathComponent
            if let id = try? DraftID(parsing: stem),
               let doc = try? loadDraft(id: id) {
                documents.append(doc)
            }
        }
        documents.sort { $0.updatedAt > $1.updatedAt }
        return documents
    }

    public func createDraft(
        title: String,
        pinnedClipIDs: [ClipID],
        initialBody: String = ""
    ) throws -> DraftDocument {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "未命名成文草稿"
            : title.trimmingCharacters(in: .whitespacesAndNewlines)

        let baseDraftID = DraftID.makeSlug(fromTitle: cleanTitle)
        var candidateID = baseDraftID
        var suffixCounter = 2
        while FileManager.default.fileExists(atPath: fileURL(for: candidateID).path) {
            candidateID = DraftID.makeSlug(fromTitle: cleanTitle, suffix: "\(suffixCounter)")
            suffixCounter += 1
        }

        let body: String
        if initialBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body = "# \(cleanTitle)\n\n"
        } else {
            body = initialBody
        }

        let draft = DraftDocument(
            id: candidateID,
            fileURL: fileURL(for: candidateID),
            title: cleanTitle,
            pinnedClipIDs: pinnedClipIDs,
            markdownBody: body,
            updatedAt: Date()
        )
        return try saveDraft(draft)
    }

    public func loadDraft(id: DraftID) throws -> DraftDocument {
        let targetURL = fileURL(for: id)
        let rawContent = try String(contentsOf: targetURL, encoding: .utf8)
        let parsed = Self.parseFileContent(rawContent, fallbackTitle: id.stem)
        let values = try? targetURL.resourceValues(forKeys: [.contentModificationDateKey])
        let updatedAt = values?.contentModificationDate ?? Date()

        return DraftDocument(
            id: id,
            fileURL: targetURL,
            title: parsed.title,
            pinnedClipIDs: parsed.pinnedClipIDs,
            markdownBody: parsed.markdownBody,
            updatedAt: updatedAt
        )
    }

    @discardableResult
    public func saveDraft(_ draft: DraftDocument) throws -> DraftDocument {
        let targetURL = fileURL(for: draft.id)
        let serialized = Self.serializeFileContent(
            pinnedClipIDs: draft.pinnedClipIDs,
            markdownBody: draft.markdownBody
        )
        try AtomicFileWriter.writeUTF8(serialized, to: targetURL, permissions: 0o644)
        let resolvedTitle = Self.extractHeadingTitle(from: draft.markdownBody) ?? draft.title
        return DraftDocument(
            id: draft.id,
            fileURL: targetURL,
            title: resolvedTitle,
            pinnedClipIDs: draft.pinnedClipIDs,
            markdownBody: draft.markdownBody,
            updatedAt: Date()
        )
    }

    public func deleteDraft(id: DraftID) throws {
        let targetURL = fileURL(for: id)
        if FileManager.default.fileExists(atPath: targetURL.path) {
            try FileManager.default.removeItem(at: targetURL)
        }
    }

    public static func appendCitedMarkdown(
        into existingBody: String,
        insertedMarkdown: String,
        citedClips: [Clip]
    ) -> String {
        var result = existingBody
        if !result.hasSuffix("\n\n") {
            if result.hasSuffix("\n") {
                result.append("\n")
            } else if !result.isEmpty {
                result.append("\n\n")
            }
        }
        result.append(insertedMarkdown.trimmingCharacters(in: .whitespacesAndNewlines))
        if !citedClips.isEmpty {
            let markers = citedClips.map { "[^clip-\($0.id.shortCode)]" }.joined(separator: " ")
            result.append(" \(markers)")
        }
        result.append("\n\n")

        for clip in citedClips {
            let footnoteTag = "[^clip-\(clip.id.shortCode)]:"
            if !result.contains(footnoteTag) {
                let promptSummary = clip.promptContext.capturedText ?? "原问题缺失"
                result.append("\(footnoteTag) 出处: \(clip.source.displayBadge) | 原问题: \(promptSummary)\n")
            }
        }
        return result
    }

    private func fileURL(for id: DraftID) -> URL {
        directoryURL.appendingPathComponent(id.filename, isDirectory: false)
    }

    private static func serializeFileContent(pinnedClipIDs: [ClipID], markdownBody: String) -> String {
        guard !pinnedClipIDs.isEmpty else {
            return markdownBody
        }
        var seen = Set<ClipID>()
        var ordered: [String] = []
        for id in pinnedClipIDs where seen.insert(id).inserted {
            ordered.append(id.rawValue)
        }
        let header = "\(headerPrefix)\(ordered.joined(separator: ","))\(headerSuffix)\n"
        return header + markdownBody
    }

    private static func parseFileContent(
        _ rawContent: String,
        fallbackTitle: String
    ) -> (title: String, pinnedClipIDs: [ClipID], markdownBody: String) {
        var body = rawContent
        var clipIDs: [ClipID] = []

        if rawContent.hasPrefix(headerPrefix),
           let newlineIndex = rawContent.firstIndex(of: "\n") {
            let firstLine = String(rawContent[..<newlineIndex])
            if firstLine.hasSuffix(headerSuffix) {
                let innerStart = firstLine.index(firstLine.startIndex, offsetBy: headerPrefix.count)
                let innerEnd = firstLine.index(firstLine.endIndex, offsetBy: -headerSuffix.count)
                if innerStart <= innerEnd {
                    let rawCSV = String(firstLine[innerStart..<innerEnd])
                    clipIDs = rawCSV
                        .split(separator: ",")
                        .compactMap { try? ClipID(parsing: String($0)) }
                }
                let nextIndex = rawContent.index(after: newlineIndex)
                body = String(rawContent[nextIndex...])
            }
        }

        let title = extractHeadingTitle(from: body) ?? fallbackTitle
        return (title, clipIDs, body)
    }

    private static func extractHeadingTitle(from markdown: String) -> String? {
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") {
                let heading = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if !heading.isEmpty {
                    return heading
                }
            }
        }
        return nil
    }
}

public enum AtomicFileWriter {
    public static func writeData(_ data: Data, to destinationURL: URL, permissions: mode_t = 0o600) throws {
        let parentDir = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        let tempFileURL = parentDir.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).tmp-\(UUID().uuidString)",
            isDirectory: false
        )
        let tempPath = tempFileURL.path
        let fd = open(tempPath, O_CREAT | O_EXCL | O_WRONLY, permissions)
        guard fd >= 0 else {
            throw StashError.writeFailed("open(\(tempPath)) errno=\(errno)")
        }

        do {
            try data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                var bytesRemaining = rawBuffer.count
                var offset = 0
                while bytesRemaining > 0 {
                    let written = Darwin.write(fd, baseAddress.advanced(by: offset), bytesRemaining)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw StashError.writeFailed("write(\(tempPath)) errno=\(errno)")
                    }
                    bytesRemaining -= written
                    offset += written
                }
            }
            _ = fchmod(fd, permissions)
            close(fd)
        } catch {
            close(fd)
            unlink(tempPath)
            throw error
        }

        if rename(tempPath, destinationURL.path) != 0 {
            let err = errno
            unlink(tempPath)
            throw StashError.writeFailed("rename(\(tempPath) -> \(destinationURL.path)) errno=\(err)")
        }
    }

    public static func writeUTF8(_ string: String, to destinationURL: URL, permissions: mode_t = 0o600) throws {
        guard let data = string.data(using: .utf8) else {
            throw StashError.writeFailed("UTF-8 encoding failed")
        }
        try writeData(data, to: destinationURL, permissions: permissions)
    }
}
