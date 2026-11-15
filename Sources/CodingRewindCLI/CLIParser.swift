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
}

public enum CLICommand: Equatable, Sendable {
    case help
    case version(json: Bool)
    case list(query: SnippetQuery, dataDir: String?, json: Bool)
    case search(query: SnippetQuery, dataDir: String?, json: Bool)
    case get(id: String, includeContext: Bool, dataDir: String?, json: Bool)
    case archive(id: String, dataDir: String?, json: Bool)
    case mcp(dataDir: String?)
}

public enum CLIParser {
    public static let versionString = "0.4.0"

    public static let usageText = """
        coding-rewind \(versionString) — Coding Rewind CLI & Embedded MCP Server

        USAGE:
          coding-rewind list [--window <72h|24h|168h|all>] [--window-hours <N>] [--status <active|ready|pending|synthesized|all>] [--source <platform>] [--limit <1..500>] [--json]
          coding-rewind search <query> [--window <72h|all|Nh>] [--window-hours <N>] [--status <active|ready|pending|synthesized|all>] [--source <platform>] [--limit <1..500>] [--json]
          coding-rewind get <id> [--no-context | --with-context] [--json]
          coding-rewind archive <id> [--json]
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
        "--limit"
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
            throw CLIValidationError("Missing subcommand. Expected one of: list, search, get, archive, mcp.")
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
        case "archive":
            guard let rawID = parsed.positionals.first else {
                throw CLIValidationError("Missing required <id> argument for 'archive'.")
            }
            guard parsed.positionals.count == 1 else {
                throw CLIValidationError("Unexpected extra argument '\(parsed.positionals[1])' for 'archive'.")
            }
            guard parsed.options.isEmpty else {
                throw CLIValidationError("Unknown option '\(parsed.options[0].name)' for 'archive'.")
            }
            let id = try SnippetFilterParser.normalizeSnippetID(rawID)
            return .archive(id: id, dataDir: parsed.dataDir, json: parsed.json)
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
                "Unknown subcommand '\(subcommand)'. Expected one of: list, search, get, archive, mcp."
            )
        }
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
