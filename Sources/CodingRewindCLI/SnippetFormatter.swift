// SPDX-License-Identifier: MIT

import CodingRewindCore
import Foundation

public enum SnippetFormatter {
    public static func encodePrettyJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    public static func formatQueryResultMarkdown(_ result: SnippetQueryResult) -> String {
        var headerParts = [
            "\(result.snippets.count) snippet\(result.snippets.count == 1 ? "" : "s")",
            "resolution: \(describeResolution(result.resolution))"
        ]
        if result.pendingOutboxCount > 0 {
            headerParts.append("pending outbox: \(result.pendingOutboxCount)")
        }
        let header = "# Coding Rewind (\(headerParts.joined(separator: ", ")))"
        guard !result.snippets.isEmpty else {
            return "\(header)\n\nNo matching snippets."
        }
        let blocks = result.snippets.map { formatSnippetBlock($0, includeContextSection: false) }
        return "\(header)\n\n" + blocks.joined(separator: "\n\n---\n\n")
    }

    public static func formatSnippetDetailMarkdown(_ record: SnippetRecord) -> String {
        formatSnippetBlock(record, includeContextSection: true)
    }

    public static func formatCreatedMarkdown(_ record: SnippetRecord) -> String {
        "Created snippet \(record.id) (status: \(record.status.rawValue))\n\n"
            + formatSnippetBlock(record, includeContextSection: false)
    }

    public static func formatUpdatedMarkdown(_ record: SnippetRecord) -> String {
        "Updated snippet \(record.id) (status: \(record.status.rawValue))\n\n"
            + formatSnippetBlock(record, includeContextSection: false)
    }

    public static func formatNotedMarkdown(_ record: SnippetRecord) -> String {
        "Appended note to snippet \(record.id) (\(record.notes.count) note\(record.notes.count == 1 ? "" : "s"))\n\n"
            + formatSnippetBlock(record, includeContextSection: true)
    }

    public static func formatArchivedMarkdown(_ record: SnippetRecord) -> String {
        "Archived snippet \(record.id) (status: \(record.status.rawValue))\n\n"
            + formatSnippetBlock(record, includeContextSection: false)
    }

    public static func formatDeletedMarkdown(_ result: SnippetDeletionResult) -> String {
        switch result.disposition {
        case .remoteAndLocal:
            return "Deleted snippet \(result.id) (remote and local cache)."
        case .localPendingOnly:
            return "Deleted offline pending snippet \(result.id)."
        case .alreadyAbsent:
            return result.deleted
                ? "Removed cached snippet \(result.id) (already absent on Memos)."
                : "Snippet \(result.id) was already absent."
        }
    }

    private static func describeResolution(_ mode: SnippetResolutionMode) -> String {
        switch mode {
        case .online:
            return "online"
        case .localOnly:
            return "localOnly"
        case .offlineFallback(let reason):
            return reason.isEmpty ? "offlineFallback" : "offlineFallback (\(reason))"
        }
    }

    private static func formatSnippetBlock(_ record: SnippetRecord, includeContextSection: Bool) -> String {
        let displayHeading = record.title.flatMap { $0.isEmpty ? nil : $0 } ?? record.sourceTitle
        var lines: [String] = [
            "## [\(record.id)] \(displayHeading)",
            "- Status: \(record.status.rawValue) · Origin: \(record.dataOrigin.rawValue) · Platform: \(record.sourcePlatform)",
            "- Created: \(MemosWireFormat.formatISO8601UTC(record.createdAt))"
        ]
        if let rawURL = record.sourceURL,
           case let safeURL = MemosWireFormat.sanitizeMarkdownURL(rawURL),
           !safeURL.isEmpty {
            let safeLabel = MemosWireFormat.escapeMarkdownLinkLabel(record.sourceTitle)
            lines.append("- Source: [\(safeLabel)](\(safeURL))")
        } else {
            lines.append("- Source: \(record.sourceTitle)")
        }
        if let session = record.sessionTopic, !session.isEmpty {
            lines.append("- Session: \(session)")
        }
        if let context = record.contextSummary, !context.isEmpty {
            lines.append("- Context: \(context)")
        }
        if !record.keywords.isEmpty {
            lines.append("- Keywords: \(record.keywords.joined(separator: ", "))")
        }
        if !record.tags.isEmpty {
            lines.append("- Tags: \(record.tags.map { "#\($0)" }.joined(separator: " "))")
        }

        var output = lines.joined(separator: "\n") + "\n\n" + record.verbatimText

        if includeContextSection, let conversationContext = record.conversationContext, !conversationContext.isEmpty {
            var ctxLines: [String] = ["", "### Conversation Context"]
            if !conversationContext.sessionTitle.isEmpty {
                ctxLines.append("- Session Title: \(conversationContext.sessionTitle)")
            }
            if let sessionID = conversationContext.sessionID, !sessionID.isEmpty {
                ctxLines.append("- Session ID: \(sessionID)")
            }
            if !conversationContext.prompt.isEmpty {
                ctxLines.append("- Prompt: \(conversationContext.prompt)")
            }
            switch conversationContext.lead {
            case .sessionOpening(let opening) where !opening.isEmpty:
                ctxLines.append("")
                ctxLines.append("#### Session Opening")
                ctxLines.append(opening)
            case .pageLead(let pageLead) where !pageLead.isEmpty:
                ctxLines.append("")
                ctxLines.append("#### Page Lead")
                ctxLines.append(pageLead)
            default:
                break
            }
            if !conversationContext.recentTurns.isEmpty {
                ctxLines.append("")
                ctxLines.append("#### Recent Turns")
                for turn in conversationContext.recentTurns {
                    ctxLines.append("- **\(turn.role)**: \(turn.text)")
                }
            }
            output += "\n" + ctxLines.joined(separator: "\n")
        }

        if includeContextSection && !record.notes.isEmpty {
            var noteLines: [String] = ["", "### Notes"]
            for note in record.notes {
                let iso = MemosWireFormat.formatISO8601UTC(note.createdAt)
                noteLines.append("#### [\(note.id)] \(note.author) · \(iso)")
                noteLines.append("")
                noteLines.append(note.content)
                noteLines.append("")
            }
            output += "\n" + noteLines.joined(separator: "\n").trimmingCharacters(in: .newlines)
        }

        return output
    }
}
