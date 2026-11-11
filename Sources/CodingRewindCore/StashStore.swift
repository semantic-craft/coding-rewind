// SPDX-License-Identifier: MIT

import Foundation
import SQLite3

private let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public actor StashStore {
    public enum Location: Equatable, Sendable {
        case inMemory
        case sqliteFile(URL)
    }

    public enum AccessMode: Equatable, Sendable {
        case readWrite
        case readOnly
    }

    public let location: Location
    public let mode: AccessMode
    private let dbAddress: Int

    public init(location: Location, mode: AccessMode = .readWrite) throws {
        self.location = location
        self.mode = mode

        let path: String
        switch location {
        case .inMemory:
            path = ":memory:"
        case .sqliteFile(let url):
            let standardized = url.standardizedFileURL
            if mode == .readWrite {
                let parent = standardized.deletingLastPathComponent()
                do {
                    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                } catch {
                    throw StashError.databaseOpenFailed(error.localizedDescription)
                }
            } else if !FileManager.default.fileExists(atPath: standardized.path) {
                throw StashError.databaseOpenFailed("File does not exist at \(standardized.path)")
            }
            path = standardized.path
        }

        let openFlags: Int32
        switch mode {
        case .readWrite:
            openFlags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        case .readOnly:
            openFlags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        }

        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, openFlags, nil)
        guard rc == SQLITE_OK, let openedHandle = handle else {
            let message = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "SQLite code \(rc)"
            if let handle {
                sqlite3_close(handle)
            }
            throw StashError.databaseOpenFailed(message)
        }
        self.dbAddress = Int(bitPattern: openedHandle)

        sqlite3_busy_timeout(openedHandle, 3000)

        if mode == .readWrite {
            try Self.execSQL(
                on: openedHandle,
                sql: """
                PRAGMA journal_mode = WAL;
                PRAGMA synchronous = NORMAL;
                PRAGMA foreign_keys = ON;
                PRAGMA secure_delete = ON;

                CREATE TABLE IF NOT EXISTS clips (
                    id TEXT PRIMARY KEY NOT NULL,
                    excerpt TEXT NOT NULL,
                    prompt_state TEXT NOT NULL,
                    prompt_text TEXT,
                    source_json TEXT NOT NULL,
                    captured_at REAL NOT NULL,
                    disposition_json TEXT NOT NULL,
                    title TEXT,
                    tags_json TEXT NOT NULL,
                    user_note TEXT
                );

                CREATE INDEX IF NOT EXISTS idx_clips_captured_at ON clips(captured_at DESC);

                CREATE VIRTUAL TABLE IF NOT EXISTS clips_fts USING fts5(
                    clip_id UNINDEXED,
                    excerpt_tokens,
                    prompt_tokens,
                    annotation_tokens,
                    source_tokens
                );

                CREATE VIRTUAL TABLE IF NOT EXISTS clips_fts_vocab USING fts5vocab(clips_fts, 'row');
                """
            )
        }
    }

    deinit {
        if let handle = OpaquePointer(bitPattern: dbAddress) {
            sqlite3_close_v2(handle)
        }
    }

    @discardableResult
    public func capture(_ newClip: NewClip, id: ClipID = ClipID()) throws -> Clip {
        try requireReadWrite()
        let clip = Clip(
            id: id,
            verbatimExcerpt: newClip.verbatimExcerpt,
            promptContext: newClip.promptContext,
            source: newClip.source,
            capturedAt: newClip.capturedAt,
            disposition: .active(reheatedAt: nil),
            annotation: newClip.annotation
        )

        try inTransaction {
            try insertOrReplaceClipRow(clip)
            try indexClipInFTS(clip)
        }
        return clip
    }

    public func clip(id: ClipID) throws -> Clip? {
        let handle = try requireDatabase()
        let sql = """
        SELECT id, excerpt, prompt_state, prompt_text, source_json, captured_at, disposition_json, title, tags_json, user_note
        FROM clips
        WHERE id = ?1
        LIMIT 1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw StashError.queryFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, index: 1, value: id.rawValue)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return try decodeClipRow(stmt)
        }
        return nil
    }

    public func clips(matching query: ClipQuery) throws -> [Clip] {
        let trimmedQuery = query.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedQuery.isEmpty {
            let allRows = try fetchAllClipsChronological()
            return filterByScope(allRows, query: query)
        }

        let analysis = NaturalLanguageSearchTokenizer.analyzeQuery(trimmedQuery)
        if analysis.isEmpty {
            return []
        }

        let ftsCandidateScores = try queryFTSCandidates(analysis: analysis)
        let allRows = try fetchAllClipsChronological()
        let scopedRows = filterByScope(allRows, query: query, applyLimit: false)
        let loweredPhrase = trimmedQuery.lowercased()

        var scoredMatches: [(clip: Clip, score: Double)] = []
        for candidate in scopedRows {
            let indexed = NaturalLanguageSearchTokenizer.indexTokens(for: candidate)
            let exactSubstringHit = candidate.excerpt.lowercased().contains(loweredPhrase)
                || (candidate.promptContext.capturedText?.lowercased().contains(loweredPhrase) ?? false)
                || (candidate.annotation.title?.lowercased().contains(loweredPhrase) ?? false)
                || (candidate.annotation.userNote?.lowercased().contains(loweredPhrase) ?? false)
                || candidate.annotation.tags.contains(where: { $0.lowercased().contains(loweredPhrase) })

            let matchedPrimaryCount = analysis.primaryTokens.filter { indexed.primaryTokenSet.contains($0) }.count
            let matchedUnigramCount = analysis.fallbackCJKUnigrams.filter { indexed.allTokenSet.contains($0) }.count

            if !exactSubstringHit {
                if !analysis.primaryTokens.isEmpty {
                    let minimumRequiredPrimary: Int
                    if analysis.primaryTokens.count >= 4 {
                        minimumRequiredPrimary = 2
                    } else {
                        minimumRequiredPrimary = 1
                    }
                    guard matchedPrimaryCount >= minimumRequiredPrimary else {
                        continue
                    }
                } else {
                    let minimumRequiredUnigrams = min(2, analysis.fallbackCJKUnigrams.count)
                    guard matchedUnigramCount >= max(1, minimumRequiredUnigrams) else {
                        continue
                    }
                }
            }

            let ftsBoost = ftsCandidateScores[candidate.id] ?? 0.0
            let totalScore = (exactSubstringHit ? 20.0 : 0.0)
                + Double(matchedPrimaryCount) * 4.0
                + Double(matchedUnigramCount) * 0.75
                + ftsBoost

            guard totalScore >= 2.0 else {
                continue
            }
            scoredMatches.append((candidate, totalScore))
        }

        scoredMatches.sort { lhs, rhs in
            if abs(lhs.score - rhs.score) > 0.001 {
                return lhs.score > rhs.score
            }
            return lhs.clip.capturedAt > rhs.clip.capturedAt
        }

        return Array(scoredMatches.prefix(query.limit).map(\.clip))
    }

    @discardableResult
    public func updateAnnotation(_ annotation: ClipAnnotation, for id: ClipID) throws -> Clip {
        try requireReadWrite()
        guard var existing = try clip(id: id) else {
            throw StashError.clipNotFound(id)
        }
        existing.annotation = annotation
        try inTransaction {
            try insertOrReplaceClipRow(existing)
            try indexClipInFTS(existing)
        }
        return existing
    }

    public func markSynthesized(
        clipIDs: Set<ClipID>,
        draftID: DraftID?,
        at date: Date = Date()
    ) throws {
        try updateDispositions(for: clipIDs, to: .synthesized(draftID: draftID, at: date))
    }

    public func cool(clipIDs: Set<ClipID>, at date: Date = Date()) throws {
        try updateDispositions(for: clipIDs, to: .cooled(at: date))
    }

    public func reheat(clipIDs: Set<ClipID>, at date: Date = Date()) throws {
        try updateDispositions(for: clipIDs, to: .active(reheatedAt: date))
    }

    public func exportClips(
        ids: Set<ClipID>? = nil,
        format: ExportFormat,
        now: Date = Date()
    ) throws -> Data {
        let allRows = try fetchAllClipsChronological()
        let selectedRows: [Clip]
        if let ids {
            selectedRows = allRows.filter { ids.contains($0.id) }
        } else {
            selectedRows = allRows
        }

        switch format {
        case .json:
            return try encodeJSONExport(selectedRows, exportedAt: now)
        case .markdown:
            let markdown = renderMarkdownExport(selectedRows, exportedAt: now)
            guard let data = markdown.data(using: .utf8) else {
                throw StashError.exportEncodingFailed
            }
            return data
        }
    }

    @discardableResult
    public func deleteClip(id: ClipID) throws -> DeletionReceipt {
        try requireReadWrite()
        let handle = try requireDatabase()
        var deletedCount = 0

        try inTransaction {
            let deleteClipSQL = "DELETE FROM clips WHERE id = ?1;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, deleteClipSQL, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw StashError.writeFailed(lastErrorMessage())
            }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, index: 1, value: id.rawValue)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw StashError.writeFailed(lastErrorMessage())
            }
            deletedCount = Int(sqlite3_changes(handle))

            let deleteFTSSQL = "DELETE FROM clips_fts WHERE clip_id = ?1;"
            var ftsStmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, deleteFTSSQL, -1, &ftsStmt, nil) == SQLITE_OK, let ftsStmt else {
                throw StashError.writeFailed(lastErrorMessage())
            }
            defer { sqlite3_finalize(ftsStmt) }
            bindText(ftsStmt, index: 1, value: id.rawValue)
            guard sqlite3_step(ftsStmt) == SQLITE_DONE else {
                throw StashError.writeFailed(lastErrorMessage())
            }
        }

        if deletedCount == 0 {
            throw StashError.clipNotFound(id)
        }

        return DeletionReceipt(
            deletedClipCount: deletedCount,
            remainingClipCount: try countRows(in: "clips"),
            remainingFTSTokenRows: try countFTSTokenRows()
        )
    }

    @discardableResult
    public func deleteAllClips(confirmation: DeleteAllConfirmation) throws -> DeletionReceipt {
        _ = confirmation
        try requireReadWrite()
        let handle = try requireDatabase()
        let priorCount = try countRows(in: "clips")

        try inTransaction {
            try Self.execSQL(
                on: handle,
                sql: """
                DELETE FROM clips;
                DELETE FROM clips_fts;
                """
            )
        }
        _ = try? Self.execSQL(on: handle, sql: "PRAGMA wal_checkpoint(TRUNCATE);")

        return DeletionReceipt(
            deletedClipCount: priorCount,
            remainingClipCount: try countRows(in: "clips"),
            remainingFTSTokenRows: try countFTSTokenRows()
        )
    }

    private func updateDispositions(for clipIDs: Set<ClipID>, to disposition: ClipDisposition) throws {
        try requireReadWrite()
        guard !clipIDs.isEmpty else { return }
        try inTransaction {
            for id in clipIDs {
                guard var existing = try clip(id: id) else {
                    throw StashError.clipNotFound(id)
                }
                existing.disposition = disposition
                try insertOrReplaceClipRow(existing)
            }
        }
    }

    private func insertOrReplaceClipRow(_ clip: Clip) throws {
        let handle = try requireDatabase()
        let sql = """
        INSERT OR REPLACE INTO clips (
            id, excerpt, prompt_state, prompt_text, source_json, captured_at, disposition_json, title, tags_json, user_note
        ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw StashError.writeFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let sourceData = try? encoder.encode(clip.source),
              let sourceJSON = String(data: sourceData, encoding: .utf8),
              let dispositionData = try? encoder.encode(clip.disposition),
              let dispositionJSON = String(data: dispositionData, encoding: .utf8),
              let tagsData = try? encoder.encode(clip.annotation.tags),
              let tagsJSON = String(data: tagsData, encoding: .utf8) else {
            throw StashError.writeFailed("JSON serialization failed")
        }

        bindText(stmt, index: 1, value: clip.id.rawValue)
        bindText(stmt, index: 2, value: clip.excerpt)
        switch clip.promptContext {
        case .captured(let text):
            bindText(stmt, index: 3, value: "captured")
            bindText(stmt, index: 4, value: text)
        case .missing:
            bindText(stmt, index: 3, value: "missing")
            sqlite3_bind_null(stmt, 4)
        }
        bindText(stmt, index: 5, value: sourceJSON)
        sqlite3_bind_double(stmt, 6, clip.capturedAt.timeIntervalSince1970)
        bindText(stmt, index: 7, value: dispositionJSON)
        bindOptionalText(stmt, index: 8, value: clip.annotation.title)
        bindText(stmt, index: 9, value: tagsJSON)
        bindOptionalText(stmt, index: 10, value: clip.annotation.userNote)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StashError.writeFailed(lastErrorMessage())
        }
    }

    private func indexClipInFTS(_ clip: Clip) throws {
        let handle = try requireDatabase()
        let deleteSQL = "DELETE FROM clips_fts WHERE clip_id = ?1;"
        var deleteStmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, deleteSQL, -1, &deleteStmt, nil) == SQLITE_OK, let deleteStmt else {
            throw StashError.writeFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(deleteStmt) }
        bindText(deleteStmt, index: 1, value: clip.id.rawValue)
        guard sqlite3_step(deleteStmt) == SQLITE_DONE else {
            throw StashError.writeFailed(lastErrorMessage())
        }

        let tokens = NaturalLanguageSearchTokenizer.indexTokens(for: clip)
        let insertSQL = """
        INSERT INTO clips_fts (clip_id, excerpt_tokens, prompt_tokens, annotation_tokens, source_tokens)
        VALUES (?1, ?2, ?3, ?4, ?5);
        """
        var insertStmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, insertSQL, -1, &insertStmt, nil) == SQLITE_OK, let insertStmt else {
            throw StashError.writeFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(insertStmt) }
        bindText(insertStmt, index: 1, value: clip.id.rawValue)
        bindText(insertStmt, index: 2, value: tokens.excerptTokens)
        bindText(insertStmt, index: 3, value: tokens.promptTokens)
        bindText(insertStmt, index: 4, value: tokens.annotationTokens)
        bindText(insertStmt, index: 5, value: tokens.sourceTokens)

        guard sqlite3_step(insertStmt) == SQLITE_DONE else {
            throw StashError.writeFailed(lastErrorMessage())
        }
    }

    private func queryFTSCandidates(analysis: QueryTokenAnalysis) throws -> [ClipID: Double] {
        let handle = try requireDatabase()
        let matchTerms = analysis.allSearchTokens.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"" }
        guard !matchTerms.isEmpty else { return [:] }
        let matchExpression = matchTerms.joined(separator: " OR ")

        let sql = """
        SELECT clip_id, bm25(clips_fts, 3.0, 2.0, 2.5, 1.0)
        FROM clips_fts
        WHERE clips_fts MATCH ?1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return [:]
        }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, index: 1, value: matchExpression)
        var scores: [ClipID: Double] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let rawIDPtr = sqlite3_column_text(stmt, 0) {
                let rawID = String(cString: rawIDPtr)
                let rawBM25 = sqlite3_column_double(stmt, 1)
                if let id = try? ClipID(parsing: rawID) {
                    scores[id] = max(0.5, -rawBM25)
                }
            }
        }
        return scores
    }

    private func fetchAllClipsChronological() throws -> [Clip] {
        let handle = try requireDatabase()
        let sql = """
        SELECT id, excerpt, prompt_state, prompt_text, source_json, captured_at, disposition_json, title, tags_json, user_note
        FROM clips
        ORDER BY captured_at DESC, id ASC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw StashError.queryFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }

        var rows: [Clip] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(try decodeClipRow(stmt))
        }
        return rows
    }

    private func filterByScope(_ clips: [Clip], query: ClipQuery, applyLimit: Bool = true) -> [Clip] {
        let filtered = clips.filter { clip in
            let state = clip.lifecycle(at: query.referenceDate, hotWindow: query.hotWindow)
            switch query.scope {
            case .hot:
                return state == .hot
            case .synthesized:
                return state == .synthesized
            case .archived:
                return state == .archived
            case .all:
                return true
            }
        }
        if applyLimit {
            return Array(filtered.prefix(query.limit))
        }
        return filtered
    }

    private func decodeClipRow(_ stmt: OpaquePointer) throws -> Clip {
        guard let idPtr = sqlite3_column_text(stmt, 0),
              let excerptPtr = sqlite3_column_text(stmt, 1),
              let promptStatePtr = sqlite3_column_text(stmt, 2),
              let sourcePtr = sqlite3_column_text(stmt, 4),
              let dispositionPtr = sqlite3_column_text(stmt, 6),
              let tagsPtr = sqlite3_column_text(stmt, 8) else {
            throw StashError.queryFailed("Malformed row in clips table")
        }

        let id = try ClipID(parsing: String(cString: idPtr))
        let excerpt = try VerbatimExcerpt(validating: String(cString: excerptPtr))
        let promptState = String(cString: promptStatePtr)
        let promptContext: PromptContext
        if promptState == "captured", let promptPtr = sqlite3_column_text(stmt, 3) {
            promptContext = PromptContext.from(raw: String(cString: promptPtr))
        } else {
            promptContext = .missing
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let sourceData = String(cString: sourcePtr).data(using: .utf8),
              let source = try? decoder.decode(ClipSource.self, from: sourceData),
              let dispositionData = String(cString: dispositionPtr).data(using: .utf8),
              let disposition = try? decoder.decode(ClipDisposition.self, from: dispositionData),
              let tagsData = String(cString: tagsPtr).data(using: .utf8),
              let tags = try? decoder.decode([String].self, from: tagsData) else {
            throw StashError.queryFailed("JSON column decode failed")
        }

        let capturedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
        let title = sqlite3_column_text(stmt, 7).map { String(cString: $0) }
        let userNote = sqlite3_column_text(stmt, 9).map { String(cString: $0) }

        return Clip(
            id: id,
            verbatimExcerpt: excerpt,
            promptContext: promptContext,
            source: source,
            capturedAt: capturedAt,
            disposition: disposition,
            annotation: ClipAnnotation(title: title, tags: tags, userNote: userNote)
        )
    }

    private func countRows(in table: String) throws -> Int {
        let handle = try requireDatabase()
        let sql = "SELECT COUNT(*) FROM \(table);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw StashError.queryFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int64(stmt, 0))
        }
        return 0
    }

    private func countFTSTokenRows() throws -> Int {
        if let vocabCount = try? countRows(in: "clips_fts_vocab") {
            return vocabCount
        }
        return try countRows(in: "clips_fts")
    }

    private func inTransaction(_ body: () throws -> Void) throws {
        let handle = try requireDatabase()
        try Self.execSQL(on: handle, sql: "BEGIN IMMEDIATE TRANSACTION;")
        do {
            try body()
            try Self.execSQL(on: handle, sql: "COMMIT TRANSACTION;")
        } catch {
            _ = try? Self.execSQL(on: handle, sql: "ROLLBACK TRANSACTION;")
            throw error
        }
    }

    private func requireReadWrite() throws {
        guard mode == .readWrite else {
            throw StashError.readOnlyStore
        }
    }

    private func requireDatabase() throws -> OpaquePointer {
        guard let handle = OpaquePointer(bitPattern: dbAddress) else {
            throw StashError.databaseOpenFailed("Database handle is invalid")
        }
        return handle
    }

    private func lastErrorMessage() -> String {
        guard let handle = OpaquePointer(bitPattern: dbAddress), let msg = sqlite3_errmsg(handle) else {
            return "Unknown SQLite error"
        }
        return String(cString: msg)
    }

    private func bindText(_ stmt: OpaquePointer, index: Int32, value: String) {
        sqlite3_bind_text(stmt, index, (value as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
    }

    private func bindOptionalText(_ stmt: OpaquePointer, index: Int32, value: String?) {
        if let value {
            bindText(stmt, index: index, value: value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private static func execSQL(on handle: OpaquePointer, sql: String) throws {
        var errorMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errorMsg)
        if rc != SQLITE_OK {
            let detail = errorMsg.map { String(cString: $0) } ?? "SQLite error \(rc)"
            if let errorMsg {
                sqlite3_free(errorMsg)
            }
            throw StashError.writeFailed(detail)
        }
    }

    private struct ExportedClipRecord: Codable, Sendable {
        let id: String
        let excerpt: String
        let promptStatus: String
        let promptText: String?
        let sourceBadge: String
        let source: ClipSource
        let capturedAtISO8601: String
        let lifecycle: String
        let annotationTitle: String?
        let annotationTags: [String]
        let annotationUserNote: String?
    }

    private struct ExportedBundle: Codable, Sendable {
        let schemaVersion: Int
        let exportedAtISO8601: String
        let clipCount: Int
        let clips: [ExportedClipRecord]
    }

    private func encodeJSONExport(_ clips: [Clip], exportedAt: Date) throws -> Data {
        let iso = ISO8601DateFormatter()
        let records = clips.map { clip in
            ExportedClipRecord(
                id: clip.id.rawValue,
                excerpt: clip.excerpt,
                promptStatus: clip.promptContext == .missing ? "missing" : "captured",
                promptText: clip.promptContext.capturedText,
                sourceBadge: clip.source.displayBadge,
                source: clip.source,
                capturedAtISO8601: iso.string(from: clip.capturedAt),
                lifecycle: clip.lifecycle(at: exportedAt).rawValue,
                annotationTitle: clip.annotation.title,
                annotationTags: clip.annotation.tags,
                annotationUserNote: clip.annotation.userNote
            )
        }
        let bundle = ExportedBundle(
            schemaVersion: 1,
            exportedAtISO8601: iso.string(from: exportedAt),
            clipCount: records.count,
            clips: records
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(bundle) else {
            throw StashError.exportEncodingFailed
        }
        return data
    }

    private func renderMarkdownExport(_ clips: [Clip], exportedAt: Date) -> String {
        let iso = ISO8601DateFormatter()
        var lines: [String] = [
            "# Coding-Rewind 片段导出",
            "",
            "- 导出时间: `\(iso.string(from: exportedAt))`",
            "- 片段总数: `\(clips.count)`",
            ""
        ]

        for (index, clip) in clips.enumerated() {
            let titleHeading = clip.annotation.title ?? "片段 #\(index + 1) (\(clip.id.shortCode))"
            lines.append("## \(titleHeading)")
            lines.append("")
            lines.append("- **ID**: `\(clip.id.rawValue)`")
            lines.append("- **出处**: \(clip.source.displayBadge)")
            if let reopenURL = clip.source.reopenURL {
                lines.append("- **原始链接**: \(reopenURL.absoluteString)")
            }
            lines.append("- **保存时间**: `\(iso.string(from: clip.capturedAt))`")
            lines.append("- **状态**: \(clip.lifecycle(at: exportedAt).displayName)")
            switch clip.promptContext {
            case .captured(let prompt):
                lines.append("- **原问题**: \(prompt)")
            case .missing:
                lines.append("- **原问题**: 原问题缺失 (未采集到触发该段落的原始提问)")
            }
            lines.append("")
            lines.append("### 选中原文 (Verbatim Excerpt)")
            lines.append("")
            lines.append("```text")
            lines.append(clip.excerpt)
            lines.append("```")
            lines.append("")
            if !clip.annotation.isEmpty {
                lines.append("### 用户后补注释 (Separated User Annotation)")
                lines.append("")
                if let customTitle = clip.annotation.title {
                    lines.append("- **自定标题**: \(customTitle)")
                }
                if !clip.annotation.tags.isEmpty {
                    lines.append("- **标签**: \(clip.annotation.tags.joined(separator: ", "))")
                }
                if let userNote = clip.annotation.userNote {
                    lines.append("- **用户笔记**: \(userNote)")
                }
                lines.append("")
            }
            lines.append("---")
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }
}
