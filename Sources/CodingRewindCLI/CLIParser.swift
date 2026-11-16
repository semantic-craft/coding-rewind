// SPDX-License-Identifier: MIT

import CodingRewindCore
import Foundation

public struct CLIValidationError: LocalizedError, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? {
        message
    }
}

public enum SnippetFilterParser {
    public static let minLimit = 1
    public static let maxLimit = 500

    public static func parseWindow(_ raw: String) throws -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else {
            throw CLIValidationError("Invalid window '\(raw)'. Expected '<N>h' (e.g. '72h', '168h') or 'all'.")
        }
        if trimmed == "all" {
            return nil
        }
        if trimmed.hasSuffix("h") {
            let numberText = String(trimmed.dropLast())
            if let hours = Double(numberText), hours.isFinite, hours > 0 {
                return hours
            }
        } else if trimmed.hasSuffix("d") {
            let numberText = String(trimmed.dropLast())
            if let days = Double(numberText), days.isFinite, days > 0 {
                return days * 24.0
            }
        }
        throw CLIValidationError("Invalid window '\(raw)'. Expected '<N>h' (e.g. '72h', '168h') or 'all'.")
    }

    public static func validateWindowHours(_ hours: Double) throws -> Double {
        guard hours.isFinite, hours > 0 else {
            throw CLIValidationError("Invalid window_hours '\(hours)'. Expected a finite number greater than 0.")
        }
        return hours
    }

    public static func parseStatus(_ raw: String) throws -> SnippetStatusFilter {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let filter = SnippetStatusFilter(rawValue: normalized) else {
            throw CLIValidationError(
                "Invalid status '\(raw)'. Expected one of: active, ready, pending, synthesized, all."
            )
        }
        return filter
    }

    public static func validateLimit(_ value: Int) throws -> Int {
        guard (minLimit...maxLimit).contains(value) else {
            throw CLIValidationError("Invalid limit '\(value)'. Expected an integer between \(minLimit) and \(maxLimit).")
        }
        return value
    }

    public static func parseLimit(_ raw: String) throws -> Int {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Int(trimmed) else {
            throw CLIValidationError("Invalid limit '\(raw)'. Expected an integer between \(minLimit) and \(maxLimit).")
        }
        return try validateLimit(parsed)
    }

    public static func normalizeNonEmpty(_ raw: String, fieldName: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CLIValidationError("Missing required \(fieldName).")
        }
        return trimmed
    }

    public static func normalizeSnippetID(_ raw: String) throws -> String {
        let trimmed = try normalizeNonEmpty(raw, fieldName: "snippet id")
        do {
            return try MemosWireFormat.normalizeSnippetID(trimmed)
        } catch {
            throw CLIValidationError("Invalid snippet id '\(raw)'.")
        }
    }

    public static func parseCustomTag(_ raw: String) throws -> String {
        guard let cleaned = MemosWireFormat.sanitizeCustomTag(raw) else {
            throw CLIValidationError(
                "Invalid tag '\(raw)'. Custom tags must be non-empty single tokens and must not use reserved 'rewind/' or 'source/' prefixes."
            )
        }
        return cleaned
    }

    public static func parsePlatform(_ raw: String) throws -> String {
        let trimmed = try normalizeNonEmpty(raw, fieldName: "source platform")
        var cleaned = trimmed
        if cleaned.lowercased().hasPrefix("#source/") {
            cleaned = String(cleaned.dropFirst("#source/".count))
        } else {
            while cleaned.hasPrefix("#") {
                cleaned.removeFirst()
            }
        }
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard !cleaned.isEmpty,
              !cleaned.contains("/"),
              cleaned.rangeOfCharacter(from: forbidden) == nil else {
            throw CLIValidationError("Invalid source platform '\(raw)'.")
        }
        return cleaned
    }

    public static func parseCommaSeparatedKeywords(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

public enum CLITextSource: Equatable, Sendable {
    case inline(String)
    case stdin
}

public enum CLICommand: Equatable, Sendable {
    case help
    case version(json: Bool)
    case list(query: SnippetQuery, dataDir: String?, json: Bool)
    case search(query: SnippetQuery, dataDir: String?, json: Bool)
    case get(id: String, includeContext: Bool, dataDir: String?, json: Bool)
    case create(textSource: CLITextSource, input: SnippetCreateInput, dataDir: String?, json: Bool)
    case update(id: String, patch: SnippetMetadataPatch, dataDir: String?, json: Bool)
    case note(id: String, textSource: CLITextSource, author: String?, dataDir: String?, json: Bool)
    case archive(id: String, dataDir: String?, json: Bool)
    case delete(id: String, dataDir: String?, json: Bool)
    case mcp(dataDir: String?)
}

public enum CLIParser {
    public static let versionString = "0.5.0"

    public static let usageText = """
        coding-rewind \(versionString) — Coding Rewind CLI & Embedded MCP Server

        USAGE:
          coding-rewind list [--window <72h|24h|168h|all>] [--window-hours <N>] [--status <active|ready|pending|synthesized|all>] [--source <platform>] [--limit <1..500>] [--json]
          coding-rewind search <query> [--window <72h|all|Nh>] [--window-hours <N>] [--status <active|ready|pending|synthesized|all>] [--source <platform>] [--limit <1..500>] [--json]
          coding-rewind get <id> [--no-context | --with-context] [--json]
          coding-rewind create (--text <markdown> | --stdin) [--title <t>] [--session <s>] [--context <c>] [--keywords <k1,k2>] [--tag <tag>...] [--source <platform>] [--source-title <st>] [--source-url <u>] [--json]
          coding-rewind update <id> [--title <t>] [--session <s>] [--context <c>] [--keywords <k1,k2>] [--add-tag <tag>...] [--remove-tag <tag>...] [--archive | --unarchive] [--json]
          coding-rewind note <id> (--text <markdown> | --stdin) [--author <name>] [--json]
          coding-rewind archive <id> [--json]
          coding-rewind delete <id> [--json]
          coding-rewind mcp

        GLOBAL OPTIONS:
          --data-dir <path>   Override Coding Rewind data directory
          --json              Output deterministic UTF-8 JSON to stdout
          -h, --help          Show this help text
          -v, --version       Show version
        """

    private struct TokenizedArgs {
        var subcommand: String?
        var positionals: [String] = []
        var options: [(name: String, value: String?)] = []
        var sawHelp = false
        var sawVersion = false
        var json = false
        var dataDir: String?
    }

    private static let valueOptions: Set<String> = [
        "--data-dir",
        "--window",
        "--window-hours",
        "--status",
        "--source",
        "--limit",
        "--text",
        "--title",
        "--session",
        "--context",
        "--keywords",
        "--tag",
        "--source-title",
        "--source-url",
        "--add-tag",
        "--remove-tag",
        "--author"
    ]

    public static func parse(arguments: [String]) throws -> CLICommand {
        let rawTokens = Array(arguments.dropFirst())
        var parsed = TokenizedArgs()
        var index = 0
        var endOfFlags = false

        while index < rawTokens.count {
            let token = rawTokens[index]
            if endOfFlags {
                if parsed.subcommand == nil {
                    parsed.subcommand = token
                } else {
                    parsed.positionals.append(token)
                }
                index += 1
                continue
            }

            if token == "--" {
                endOfFlags = true
                index += 1
                continue
            }

            if token == "-h" || token == "--help" {
                parsed.sawHelp = true
                index += 1
                continue
            }

            if token == "-v" || token == "--version" {
                parsed.sawVersion = true
                index += 1
                continue
            }

            if token == "--json" {
                parsed.json = true
                index += 1
                continue
            }

            if token.hasPrefix("--") {
                let flagName: String
                let inlineValue: String?
                if let eqIdx = token.firstIndex(of: "=") {
                    flagName = String(token[..<eqIdx])
                    inlineValue = String(token[token.index(after: eqIdx)...])
                } else {
                    flagName = token
                    inlineValue = nil
                }

                if valueOptions.contains(flagName) {
                    let resolvedValue: String
                    if let inlineValue {
                        resolvedValue = inlineValue
                    } else {
                        guard index + 1 < rawTokens.count else {
                            throw CLIValidationError("Option '\(flagName)' requires a value.")
                        }
                        index += 1
                        resolvedValue = rawTokens[index]
                    }

                    if flagName == "--data-dir" {
                        parsed.dataDir = try SnippetFilterParser.normalizeNonEmpty(resolvedValue, fieldName: "--data-dir path")
                    } else {
                        parsed.options.append((name: flagName, value: resolvedValue))
                    }
                    index += 1
                    continue
                } else {
                    parsed.options.append((name: flagName, value: inlineValue))
                    index += 1
                    continue
                }
            }

            if token.hasPrefix("-") && token.count > 1 {
                throw CLIValidationError("Unknown option '\(token)'. Run 'coding-rewind --help' for usage.")
            }

            if parsed.subcommand == nil {
                parsed.subcommand = token
            } else {
                parsed.positionals.append(token)
            }
            index += 1
        }

        if parsed.sawHelp {
            return .help
        }
        if parsed.sawVersion {
            return .version(json: parsed.json)
        }

        guard let subcommand = parsed.subcommand else {
            throw CLIValidationError(
                "Missing subcommand. Expected one of: list, search, get, create, update, note, archive, delete, mcp."
            )
        }

        switch subcommand {
        case "help":
            return .help
        case "version":
            return .version(json: parsed.json)
        case "list":
            guard parsed.positionals.isEmpty else {
                throw CLIValidationError("Unexpected argument '\(parsed.positionals[0])' for 'list'.")
            }
            let query = try parseListOrSearchOptions(parsed.options, searchText: nil, defaultLimit: 50)
            return .list(query: query, dataDir: parsed.dataDir, json: parsed.json)
        case "search":
            guard let rawQuery = parsed.positionals.first else {
                throw CLIValidationError("Missing required <query> argument for 'search'.")
            }
            guard parsed.positionals.count == 1 else {
                throw CLIValidationError("Unexpected extra argument '\(parsed.positionals[1])' for 'search'.")
            }
            let normalizedQuery = try SnippetFilterParser.normalizeNonEmpty(rawQuery, fieldName: "search query")
            let query = try parseListOrSearchOptions(parsed.options, searchText: normalizedQuery, defaultLimit: 50)
            return .search(query: query, dataDir: parsed.dataDir, json: parsed.json)
        case "get":
            guard let rawID = parsed.positionals.first else {
                throw CLIValidationError("Missing required <id> argument for 'get'.")
            }
            guard parsed.positionals.count == 1 else {
                throw CLIValidationError("Unexpected extra argument '\(parsed.positionals[1])' for 'get'.")
            }
            let id = try SnippetFilterParser.normalizeSnippetID(rawID)
            var includeContext = true
            for option in parsed.options {
                switch option.name {
                case "--no-context":
                    guard option.value == nil else {
                        throw CLIValidationError("Option '--no-context' does not take a value.")
                    }
                    includeContext = false
                case "--with-context":
                    guard option.value == nil else {
                        throw CLIValidationError("Option '--with-context' does not take a value.")
                    }
                    includeContext = true
                default:
                    throw CLIValidationError("Unknown option '\(option.name)' for 'get'.")
                }
            }
            return .get(id: id, includeContext: includeContext, dataDir: parsed.dataDir, json: parsed.json)
        case "create":
            guard parsed.positionals.isEmpty else {
                throw CLIValidationError("Unexpected argument '\(parsed.positionals[0])' for 'create'.")
            }
            let (textSource, createInput) = try parseCreateOptions(parsed.options)
            return .create(textSource: textSource, input: createInput, dataDir: parsed.dataDir, json: parsed.json)
        case "update":
            guard let rawID = parsed.positionals.first else {
                throw CLIValidationError("Missing required <id> argument for 'update'.")
            }
            guard parsed.positionals.count == 1 else {
                throw CLIValidationError("Unexpected extra argument '\(parsed.positionals[1])' for 'update'.")
            }
            let id = try SnippetFilterParser.normalizeSnippetID(rawID)
            let patch = try parseUpdateOptions(parsed.options)
            return .update(id: id, patch: patch, dataDir: parsed.dataDir, json: parsed.json)
        case "note":
            guard let rawID = parsed.positionals.first else {
                throw CLIValidationError("Missing required <id> argument for 'note'.")
            }
            guard parsed.positionals.count == 1 else {
                throw CLIValidationError("Unexpected extra argument '\(parsed.positionals[1])' for 'note'.")
            }
            let id = try SnippetFilterParser.normalizeSnippetID(rawID)
            let (textSource, author) = try parseNoteOptions(parsed.options)
            return .note(id: id, textSource: textSource, author: author, dataDir: parsed.dataDir, json: parsed.json)
        case "archive":
            let id = try parseSingleIDArguments(parsed, subcommand: "archive")
            return .archive(id: id, dataDir: parsed.dataDir, json: parsed.json)
        case "delete":
            let id = try parseSingleIDArguments(parsed, subcommand: "delete")
            return .delete(id: id, dataDir: parsed.dataDir, json: parsed.json)
        case "mcp":
            guard parsed.positionals.isEmpty else {
                throw CLIValidationError("Unexpected argument '\(parsed.positionals[0])' for 'mcp'.")
            }
            guard parsed.options.isEmpty else {
                throw CLIValidationError("Unknown option '\(parsed.options[0].name)' for 'mcp'.")
            }
            return .mcp(dataDir: parsed.dataDir)
        default:
            throw CLIValidationError(
                "Unknown subcommand '\(subcommand)'. Expected one of: list, search, get, create, update, note, archive, delete, mcp."
            )
        }
    }

    private static func parseCreateOptions(
        _ options: [(name: String, value: String?)]
    ) throws -> (CLITextSource, SnippetCreateInput) {
        var inlineText: String?
        var sawStdin = false
        var title: String?
        var sessionTopic: String?
        var contextSummary: String?
        var keywords: [String] = []
        var tags: [String] = []
        var sourcePlatform = "agent"
        var sourceTitle: String?
        var sourceURL: String?

        for option in options {
            switch option.name {
            case "--text":
                guard inlineText == nil else {
                    throw CLIValidationError("Option '--text' may only be specified once.")
                }
                let raw = option.value ?? ""
                guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw CLIValidationError("Missing required snippet text for '--text'.")
                }
                inlineText = raw
            case "--stdin":
                guard option.value == nil else {
                    throw CLIValidationError("Option '--stdin' does not take a value.")
                }
                sawStdin = true
            case "--title":
                title = try SnippetFilterParser.normalizeNonEmpty(option.value ?? "", fieldName: "--title")
            case "--session":
                sessionTopic = try SnippetFilterParser.normalizeNonEmpty(option.value ?? "", fieldName: "--session")
            case "--context":
                contextSummary = try SnippetFilterParser.normalizeNonEmpty(option.value ?? "", fieldName: "--context")
            case "--keywords":
                keywords.append(contentsOf: SnippetFilterParser.parseCommaSeparatedKeywords(option.value ?? ""))
            case "--tag":
                tags.append(try SnippetFilterParser.parseCustomTag(option.value ?? ""))
            case "--source":
                sourcePlatform = try SnippetFilterParser.parsePlatform(option.value ?? "")
            case "--source-title":
                sourceTitle = try SnippetFilterParser.normalizeNonEmpty(option.value ?? "", fieldName: "--source-title")
            case "--source-url":
                sourceURL = try SnippetFilterParser.normalizeNonEmpty(option.value ?? "", fieldName: "--source-url")
            default:
                throw CLIValidationError("Unknown option '\(option.name)' for 'create'.")
            }
        }

        if inlineText != nil && sawStdin {
            throw CLIValidationError("Specify either '--text' or '--stdin', not both.")
        }
        let textSource: CLITextSource
        let initialText: String
        if let inlineText {
            textSource = .inline(inlineText)
            initialText = inlineText
        } else if sawStdin {
            textSource = .stdin
            initialText = ""
        } else {
            throw CLIValidationError("Missing snippet text for 'create'. Pass '--text <markdown>' or '--stdin'.")
        }

        let input = SnippetCreateInput(
            text: initialText,
            title: title,
            sessionTopic: sessionTopic,
            contextSummary: contextSummary,
            keywords: keywords,
            tags: tags,
            sourcePlatform: sourcePlatform,
            sourceTitle: sourceTitle,
            sourceURL: sourceURL
        )
        return (textSource, input)
    }

    private static func parseUpdateOptions(
        _ options: [(name: String, value: String?)]
    ) throws -> SnippetMetadataPatch {
        var title: String?
        var sessionTopic: String?
        var contextSummary: String?
        var keywords: [String]?
        var addTags: [String] = []
        var removeTags: [String] = []
        var sawArchive = false
        var sawUnarchive = false

        for option in options {
            switch option.name {
            case "--title":
                title = option.value ?? ""
            case "--session":
                sessionTopic = option.value ?? ""
            case "--context":
                contextSummary = option.value ?? ""
            case "--keywords":
                let parsed = SnippetFilterParser.parseCommaSeparatedKeywords(option.value ?? "")
                if var existing = keywords {
                    existing.append(contentsOf: parsed)
                    keywords = existing
                } else {
                    keywords = parsed
                }
            case "--add-tag":
                addTags.append(try SnippetFilterParser.parseCustomTag(option.value ?? ""))
            case "--remove-tag":
                removeTags.append(try SnippetFilterParser.parseCustomTag(option.value ?? ""))
            case "--archive":
                guard option.value == nil else {
                    throw CLIValidationError("Option '--archive' does not take a value.")
                }
                sawArchive = true
            case "--unarchive":
                guard option.value == nil else {
                    throw CLIValidationError("Option '--unarchive' does not take a value.")
                }
                sawUnarchive = true
            default:
                throw CLIValidationError("Unknown option '\(option.name)' for 'update'.")
            }
        }

        if sawArchive && sawUnarchive {
            throw CLIValidationError("Specify either '--archive' or '--unarchive', not both.")
        }
        let archived: Bool? = sawArchive ? true : (sawUnarchive ? false : nil)
        let patch = SnippetMetadataPatch(
            title: title,
            sessionTopic: sessionTopic,
            contextSummary: contextSummary,
            keywords: keywords,
            addTags: addTags,
            removeTags: removeTags,
            archived: archived
        )
        guard !patch.isEmpty else {
            throw CLIValidationError("Specify at least one update flag for 'update'.")
        }
        return patch
    }

    private static func parseNoteOptions(
        _ options: [(name: String, value: String?)]
    ) throws -> (CLITextSource, String?) {
        var inlineText: String?
        var sawStdin = false
        var author: String?

        for option in options {
            switch option.name {
            case "--text":
                guard inlineText == nil else {
                    throw CLIValidationError("Option '--text' may only be specified once.")
                }
                let raw = option.value ?? ""
                guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw CLIValidationError("Missing required note text for '--text'.")
                }
                inlineText = raw
            case "--stdin":
                guard option.value == nil else {
                    throw CLIValidationError("Option '--stdin' does not take a value.")
                }
                sawStdin = true
            case "--author":
                author = try SnippetFilterParser.normalizeNonEmpty(option.value ?? "", fieldName: "--author")
            default:
                throw CLIValidationError("Unknown option '\(option.name)' for 'note'.")
            }
        }

        if inlineText != nil && sawStdin {
            throw CLIValidationError("Specify either '--text' or '--stdin', not both.")
        }
        if let inlineText {
            return (.inline(inlineText), author)
        }
        if sawStdin {
            return (.stdin, author)
        }
        throw CLIValidationError("Missing note text for 'note'. Pass '--text <markdown>' or '--stdin'.")
    }

    private static func parseSingleIDArguments(_ parsed: TokenizedArgs, subcommand: String) throws -> String {
        guard let rawID = parsed.positionals.first else {
            throw CLIValidationError("Missing required <id> argument for '\(subcommand)'.")
        }
        guard parsed.positionals.count == 1 else {
            throw CLIValidationError("Unexpected extra argument '\(parsed.positionals[1])' for '\(subcommand)'.")
        }
        guard parsed.options.isEmpty else {
            throw CLIValidationError("Unknown option '\(parsed.options[0].name)' for '\(subcommand)'.")
        }
        return try SnippetFilterParser.normalizeSnippetID(rawID)
    }

    private static func parseListOrSearchOptions(
        _ options: [(name: String, value: String?)],
        searchText: String?,
        defaultLimit: Int
    ) throws -> SnippetQuery {
        var windowHours: Double? = 72
        var status: SnippetStatusFilter = .active
        var sourcePlatform: String?
        var limit = defaultLimit

        for option in options {
            switch option.name {
            case "--window":
                let raw = option.value ?? ""
                windowHours = try SnippetFilterParser.parseWindow(raw)
            case "--window-hours":
                let raw = (option.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard let parsed = Double(raw) else {
                    throw CLIValidationError("Invalid --window-hours '\(raw)'. Expected a positive number.")
                }
                windowHours = try SnippetFilterParser.validateWindowHours(parsed)
            case "--status":
                status = try SnippetFilterParser.parseStatus(option.value ?? "")
            case "--source":
                sourcePlatform = try SnippetFilterParser.normalizeNonEmpty(option.value ?? "", fieldName: "--source platform")
            case "--limit":
                limit = try SnippetFilterParser.parseLimit(option.value ?? "")
            default:
                throw CLIValidationError("Unknown option '\(option.name)'.")
            }
        }

        return SnippetQuery(
            windowHours: windowHours,
            status: status,
            sourcePlatform: sourcePlatform,
            searchText: searchText,
            limit: limit
        )
    }
}
