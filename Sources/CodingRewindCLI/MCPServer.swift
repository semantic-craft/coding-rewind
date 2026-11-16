// SPDX-License-Identifier: MIT

import CodingRewindCore
import Darwin
import Foundation

public struct MCPServer: Sendable {
    public static let serverName = "coding-rewind"
    public static let serverVersion = CLIParser.versionString
    public static let maxLineBytes = 4 * 1024 * 1024
    public static let defaultProtocolVersion = "2024-11-05"
    public static let supportedProtocolVersions: Set<String> = [
        "2024-11-05",
        "2025-03-26",
        "2025-06-18"
    ]

    public static let mutatingToolNames: Set<String> = [
        "create_snippet",
        "update_snippet_metadata",
        "append_snippet_note",
        "archive_snippet"
    ]

    private let repositoryProvider: @Sendable () throws -> any SnippetQuerying
    private let accessModeProvider: @Sendable () -> AIAccessMode
    private let now: @Sendable () -> Date

    public init(
        repositoryProvider: @escaping @Sendable () throws -> any SnippetQuerying,
        accessModeProvider: @escaping @Sendable () -> AIAccessMode = { .readWrite },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.repositoryProvider = repositoryProvider
        self.accessModeProvider = accessModeProvider
        self.now = now
    }

    public func run(inputFD: Int32 = STDIN_FILENO, outputFD: Int32 = STDOUT_FILENO) async -> Int32 {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        var discardingOversizedLine = false

        while true {
            let bytesRead = Darwin.read(inputFD, &chunk, chunk.count)
            if bytesRead < 0 {
                if errno == EINTR { continue }
                return 1
            }
            if bytesRead == 0 {
                if discardingOversizedLine {
                    guard writeOversizedLineError(to: outputFD) else { return 1 }
                } else if !buffer.isEmpty {
                    guard await processLineData(buffer, outputFD: outputFD) else { return 1 }
                    buffer.removeAll()
                }
                return 0
            }

            var sliceStart = 0
            while sliceStart < bytesRead {
                if discardingOversizedLine {
                    if let relNewline = chunk[sliceStart..<bytesRead].firstIndex(of: 0x0A) {
                        discardingOversizedLine = false
                        sliceStart = relNewline + 1
                        guard writeOversizedLineError(to: outputFD) else { return 1 }
                    } else {
                        sliceStart = bytesRead
                    }
                    continue
                }

                if let relNewline = chunk[sliceStart..<bytesRead].firstIndex(of: 0x0A) {
                    let pieceCount = relNewline - sliceStart
                    if buffer.count + pieceCount > Self.maxLineBytes {
                        buffer.removeAll(keepingCapacity: false)
                        sliceStart = relNewline + 1
                        guard writeOversizedLineError(to: outputFD) else { return 1 }
                    } else {
                        buffer.append(contentsOf: chunk[sliceStart..<relNewline])
                        let lineData = buffer
                        buffer.removeAll(keepingCapacity: true)
                        sliceStart = relNewline + 1
                        guard await processLineData(lineData, outputFD: outputFD) else { return 1 }
                    }
                } else {
                    let pieceCount = bytesRead - sliceStart
                    if buffer.count + pieceCount > Self.maxLineBytes {
                        buffer.removeAll(keepingCapacity: false)
                        discardingOversizedLine = true
                    } else {
                        buffer.append(contentsOf: chunk[sliceStart..<bytesRead])
                    }
                    sliceStart = bytesRead
                }
            }
        }
    }

    public func handleLine(_ lineData: Data) async -> Data? {
        var trimmed = lineData
        while let last = trimmed.last, last == 0x0D || last == 0x0A {
            trimmed.removeLast()
        }
        if trimmed.count > Self.maxLineBytes {
            let errResponse = makeErrorResponse(id: .null, code: -32600, message: "Invalid Request")
            return try? JSONValue.encodeSingleLine(errResponse)
        }
        let lineString = String(decoding: trimmed, as: UTF8.self)
        if lineString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }

        let decoded: JSONValue
        do {
            decoded = try JSONValue.decode(from: trimmed)
        } catch {
            let errResponse = makeErrorResponse(id: .null, code: -32700, message: "Parse error")
            return try? JSONValue.encodeSingleLine(errResponse)
        }

        switch decoded {
        case .object(let object):
            guard let response = await handleMessageObject(object) else {
                return nil
            }
            return try? JSONValue.encodeSingleLine(response)
        case .array(let items):
            guard !items.isEmpty else {
                let errResponse = makeErrorResponse(id: .null, code: -32600, message: "Invalid Request")
                return try? JSONValue.encodeSingleLine(errResponse)
            }
            var responses: [JSONValue] = []
            for item in items {
                if case .object(let obj) = item {
                    if let resp = await handleMessageObject(obj) {
                        responses.append(resp)
                    }
                } else {
                    responses.append(makeErrorResponse(id: .null, code: -32600, message: "Invalid Request"))
                }
            }
            guard !responses.isEmpty else { return nil }
            return try? JSONValue.encodeSingleLine(.array(responses))
        default:
            let errResponse = makeErrorResponse(id: .null, code: -32600, message: "Invalid Request")
            return try? JSONValue.encodeSingleLine(errResponse)
        }
    }

    private func processLineData(_ lineData: Data, outputFD: Int32) async -> Bool {
        guard let responseData = await handleLine(lineData) else { return true }
        return CLIRunner.writeAll(responseData, to: outputFD)
    }

    private func writeOversizedLineError(to outputFD: Int32) -> Bool {
        let errResponse = makeErrorResponse(id: .null, code: -32600, message: "Invalid Request")
        guard let responseData = try? JSONValue.encodeSingleLine(errResponse) else { return true }
        return CLIRunner.writeAll(responseData, to: outputFD)
    }

    private func handleMessageObject(_ object: [String: JSONValue]) async -> JSONValue? {
        let hasID = object.keys.contains("id")
        let requestID = object["id"] ?? .null

        if hasID {
            switch requestID {
            case .string, .int, .double, .null:
                break
            case .bool, .array, .object:
                return makeErrorResponse(id: .null, code: -32600, message: "Invalid Request: invalid id type")
            }
        }

        guard case .string(let jsonrpc) = object["jsonrpc"], jsonrpc == "2.0",
              case .string(let method) = object["method"], !method.isEmpty else {
            return makeErrorResponse(id: hasID ? requestID : .null, code: -32600, message: "Invalid Request")
        }

        if !hasID {
            return nil
        }

        let params: [String: JSONValue]
        if let rawParams = object["params"] {
            switch rawParams {
            case .object(let dict):
                params = dict
            case .null:
                params = [:]
            default:
                return makeErrorResponse(id: requestID, code: -32602, message: "Invalid params: expected object")
            }
        } else {
            params = [:]
        }

        switch method {
        case "initialize":
            let requestedVersion: String?
            if case .string(let v) = params["protocolVersion"] {
                requestedVersion = v
            } else {
                requestedVersion = nil
            }
            let negotiatedVersion: String
            if let requestedVersion, Self.supportedProtocolVersions.contains(requestedVersion) {
                negotiatedVersion = requestedVersion
            } else {
                negotiatedVersion = Self.defaultProtocolVersion
            }
            return makeSuccessResponse(
                id: requestID,
                result: .object([
                    "protocolVersion": .string(negotiatedVersion),
                    "capabilities": .object([
                        "tools": .object([:])
                    ]),
                    "serverInfo": .object([
                        "name": .string(Self.serverName),
                        "version": .string(Self.serverVersion)
                    ])
                ])
            )

        case "ping":
            return makeSuccessResponse(id: requestID, result: .object([:]))

        case "tools/list":
            return makeSuccessResponse(
                id: requestID,
                result: .object([
                    "tools": .array(Self.toolDefinitions)
                ])
            )

        case "resources/list":
            return makeSuccessResponse(
                id: requestID,
                result: .object([
                    "resources": .array([])
                ])
            )

        case "resources/templates/list":
            return makeSuccessResponse(
                id: requestID,
                result: .object([
                    "resourceTemplates": .array([])
                ])
            )

        case "prompts/list":
            return makeSuccessResponse(
                id: requestID,
                result: .object([
                    "prompts": .array([])
                ])
            )

        case "tools/call":
            guard case .string(let toolName) = params["name"], !toolName.isEmpty else {
                return makeErrorResponse(id: requestID, code: -32602, message: "Invalid params: missing tool 'name'")
            }
            let arguments: [String: JSONValue]
            if let rawArgs = params["arguments"] {
                switch rawArgs {
                case .object(let dict):
                    arguments = dict
                case .null:
                    arguments = [:]
                default:
                    return makeToolResultResponse(
                        id: requestID,
                        text: "Invalid tool arguments: expected a JSON object.",
                        isError: true
                    )
                }
            } else {
                arguments = [:]
            }
            let result = await executeTool(name: toolName, arguments: arguments)
            return makeToolResultResponse(id: requestID, text: result.text, isError: result.isError)

        default:
            return makeErrorResponse(id: requestID, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func executeTool(
        name: String,
        arguments: [String: JSONValue]
    ) async -> (text: String, isError: Bool) {
        do {
            if Self.mutatingToolNames.contains(name), accessModeProvider() == .readOnly {
                throw RewindError.aiWriteDisabled
            }

            switch name {
            case "list_snippets":
                let query = try Self.parseListArguments(arguments)
                let repository = try repositoryProvider()
                let result = try await repository.listSnippets(query, now: now())
                let json = try SnippetFormatter.encodePrettyJSON(result)
                return (json, false)

            case "search_snippets":
                let query = try Self.parseSearchArguments(arguments)
                let repository = try repositoryProvider()
                let result = try await repository.listSnippets(query, now: now())
                let json = try SnippetFormatter.encodePrettyJSON(result)
                return (json, false)

            case "get_snippet":
                let (id, includeContext) = try Self.parseGetArguments(arguments)
                let repository = try repositoryProvider()
                let record = try await repository.getSnippet(id: id, includeContext: includeContext, now: now())
                let json = try SnippetFormatter.encodePrettyJSON(record)
                return (json, false)

            case "archive_snippet":
                let id = try Self.parseArchiveArguments(arguments)
                let repository = try repositoryProvider()
                let record = try await repository.archiveSnippet(id: id)
                let json = try SnippetFormatter.encodePrettyJSON(record)
                return (json, false)

            case "create_snippet":
                let input = try Self.parseCreateArguments(arguments)
                let repository = try repositoryProvider()
                let record = try await repository.createSnippet(input, now: now())
                let json = try SnippetFormatter.encodePrettyJSON(record)
                return (json, false)

            case "update_snippet_metadata":
                let (id, patch) = try Self.parseUpdateMetadataArguments(arguments)
                let repository = try repositoryProvider()
                let record = try await repository.updateSnippetMetadata(id: id, patch: patch, now: now())
                let json = try SnippetFormatter.encodePrettyJSON(record)
                return (json, false)

            case "append_snippet_note":
                let (id, input) = try Self.parseAppendNoteArguments(arguments)
                let repository = try repositoryProvider()
                let record = try await repository.appendSnippetNote(id: id, input: input, now: now())
                let json = try SnippetFormatter.encodePrettyJSON(record)
                return (json, false)

            default:
                return (
                    "Unknown tool '\(name)'. Supported tools: list_snippets, search_snippets, get_snippet, archive_snippet, create_snippet, update_snippet_metadata, append_snippet_note.",
                    true
                )
            }
        } catch {
            return (Self.describeError(error), true)
        }
    }

    private static func describeError(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let desc = localized.errorDescription, !desc.isEmpty {
            return desc
        }
        return String(describing: error)
    }

    private static func rejectUnknownKeys(_ arguments: [String: JSONValue], allowed: Set<String>, toolName: String) throws {
        for key in arguments.keys.sorted() where !allowed.contains(key) {
            throw CLIValidationError("Unknown argument '\(key)' for \(toolName).")
        }
    }

    private static func parseOptionalString(_ arguments: [String: JSONValue], key: String) throws -> String? {
        guard let raw = arguments[key], raw != .null else { return nil }
        guard case .string(let text) = raw else {
            throw CLIValidationError("Argument '\(key)' must be a string.")
        }
        return text
    }

    private static func parseRequiredString(_ arguments: [String: JSONValue], key: String) throws -> String {
        guard let raw = arguments[key], raw != .null else {
            throw CLIValidationError("Missing required argument '\(key)'.")
        }
        guard case .string(let text) = raw else {
            throw CLIValidationError("Argument '\(key)' must be a string.")
        }
        return try SnippetFilterParser.normalizeNonEmpty(text, fieldName: "'\(key)'")
    }

    private static func parseOptionalNumber(_ arguments: [String: JSONValue], key: String) throws -> Double? {
        guard let raw = arguments[key], raw != .null else { return nil }
        switch raw {
        case .int(let i):
            return Double(i)
        case .double(let d):
            return d
        default:
            throw CLIValidationError("Argument '\(key)' must be a number.")
        }
    }

    private static func parseOptionalInt(_ arguments: [String: JSONValue], key: String) throws -> Int? {
        guard let raw = arguments[key], raw != .null else { return nil }
        guard case .int(let i) = raw, let exact = Int(exactly: i) else {
            throw CLIValidationError("Argument '\(key)' must be an integer.")
        }
        return exact
    }

    private static func parseOptionalBool(_ arguments: [String: JSONValue], key: String) throws -> Bool? {
        guard let raw = arguments[key], raw != .null else { return nil }
        guard case .bool(let b) = raw else {
            throw CLIValidationError("Argument '\(key)' must be a boolean.")
        }
        return b
    }

    private static func resolveWindowHours(
        windowString: String?,
        windowHoursNumber: Double?
    ) throws -> Double? {
        if windowString != nil && windowHoursNumber != nil {
            throw CLIValidationError("Specify either 'window' or 'window_hours', not both.")
        }
        if let windowHoursNumber {
            return try SnippetFilterParser.validateWindowHours(windowHoursNumber)
        }
        if let windowString {
            return try SnippetFilterParser.parseWindow(windowString)
        }
        return 72.0
    }

    private static func parseListArguments(_ arguments: [String: JSONValue]) throws -> SnippetQuery {
        try rejectUnknownKeys(
            arguments,
            allowed: ["window", "window_hours", "status", "source", "limit"],
            toolName: "list_snippets"
        )
        let windowRaw = try parseOptionalString(arguments, key: "window")
        let windowHoursRaw = try parseOptionalNumber(arguments, key: "window_hours")
        let windowHours = try resolveWindowHours(windowString: windowRaw, windowHoursNumber: windowHoursRaw)

        let status: SnippetStatusFilter
        if let statusRaw = try parseOptionalString(arguments, key: "status") {
            status = try SnippetFilterParser.parseStatus(statusRaw)
        } else {
            status = .active
        }

        let sourcePlatform: String?
        if let sourceRaw = try parseOptionalString(arguments, key: "source") {
            let trimmed = sourceRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            sourcePlatform = trimmed.isEmpty ? nil : trimmed
        } else {
            sourcePlatform = nil
        }

        let limit: Int
        if let limitRaw = try parseOptionalInt(arguments, key: "limit") {
            limit = try SnippetFilterParser.validateLimit(limitRaw)
        } else {
            limit = 50
        }

        return SnippetQuery(
            windowHours: windowHours,
            status: status,
            sourcePlatform: sourcePlatform,
            searchText: nil,
            limit: limit
        )
    }

    private static func parseSearchArguments(_ arguments: [String: JSONValue]) throws -> SnippetQuery {
        try rejectUnknownKeys(
            arguments,
            allowed: ["query", "window", "window_hours", "status", "source", "limit"],
            toolName: "search_snippets"
        )
        let queryText = try parseRequiredString(arguments, key: "query")
        let windowRaw = try parseOptionalString(arguments, key: "window")
        let windowHoursRaw = try parseOptionalNumber(arguments, key: "window_hours")
        let windowHours = try resolveWindowHours(windowString: windowRaw, windowHoursNumber: windowHoursRaw)

        let status: SnippetStatusFilter
        if let statusRaw = try parseOptionalString(arguments, key: "status") {
            status = try SnippetFilterParser.parseStatus(statusRaw)
        } else {
            status = .active
        }

        let sourcePlatform: String?
        if let sourceRaw = try parseOptionalString(arguments, key: "source") {
            let trimmed = sourceRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            sourcePlatform = trimmed.isEmpty ? nil : trimmed
        } else {
            sourcePlatform = nil
        }

        let limit: Int
        if let limitRaw = try parseOptionalInt(arguments, key: "limit") {
            limit = try SnippetFilterParser.validateLimit(limitRaw)
        } else {
            limit = 20
        }

        return SnippetQuery(
            windowHours: windowHours,
            status: status,
            sourcePlatform: sourcePlatform,
            searchText: queryText,
            limit: limit
        )
    }

    private static func parseGetArguments(_ arguments: [String: JSONValue]) throws -> (id: String, includeContext: Bool) {
        try rejectUnknownKeys(
            arguments,
            allowed: ["id", "include_context"],
            toolName: "get_snippet"
        )
        let rawID = try parseRequiredString(arguments, key: "id")
        let id = try SnippetFilterParser.normalizeSnippetID(rawID)
        let includeContext = try parseOptionalBool(arguments, key: "include_context") ?? true
        return (id, includeContext)
    }

    private static func parseArchiveArguments(_ arguments: [String: JSONValue]) throws -> String {
        try rejectUnknownKeys(
            arguments,
            allowed: ["id"],
            toolName: "archive_snippet"
        )
        let rawID = try parseRequiredString(arguments, key: "id")
        return try SnippetFilterParser.normalizeSnippetID(rawID)
    }

    private static func parseRequiredVerbatimString(_ arguments: [String: JSONValue], key: String) throws -> String {
        guard let raw = arguments[key], raw != .null else {
            throw CLIValidationError("Missing required argument '\(key)'.")
        }
        guard case .string(let text) = raw else {
            throw CLIValidationError("Argument '\(key)' must be a string.")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIValidationError("Missing required '\(key)'.")
        }
        return text
    }

    private static func parseOptionalStringArray(_ arguments: [String: JSONValue], key: String) throws -> [String]? {
        guard let raw = arguments[key], raw != .null else { return nil }
        guard case .array(let items) = raw else {
            throw CLIValidationError("Argument '\(key)' must be an array of strings.")
        }
        var out: [String] = []
        out.reserveCapacity(items.count)
        for item in items {
            guard case .string(let s) = item else {
                throw CLIValidationError("Argument '\(key)' must be an array of strings.")
            }
            out.append(s)
        }
        return out
    }

    private static func parseCreateArguments(_ arguments: [String: JSONValue]) throws -> SnippetCreateInput {
        try rejectUnknownKeys(
            arguments,
            allowed: [
                "text",
                "title",
                "session_topic",
                "context_summary",
                "keywords",
                "tags",
                "source",
                "source_title",
                "source_url"
            ],
            toolName: "create_snippet"
        )
        let text = try parseRequiredVerbatimString(arguments, key: "text")
        let title = try parseOptionalString(arguments, key: "title")
        let sessionTopic = try parseOptionalString(arguments, key: "session_topic")
        let contextSummary = try parseOptionalString(arguments, key: "context_summary")
        let rawKeywords = try parseOptionalStringArray(arguments, key: "keywords") ?? []
        let keywords = rawKeywords.flatMap(SnippetFilterParser.parseCommaSeparatedKeywords)
        let rawTags = try parseOptionalStringArray(arguments, key: "tags") ?? []
        let tags = try rawTags.map(SnippetFilterParser.parseCustomTag)

        let sourcePlatform: String
        if let rawSource = try parseOptionalString(arguments, key: "source"),
           !rawSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sourcePlatform = try SnippetFilterParser.parsePlatform(rawSource)
        } else {
            sourcePlatform = "agent"
        }

        let sourceTitle = try parseOptionalString(arguments, key: "source_title")
        let sourceURL = try parseOptionalString(arguments, key: "source_url")

        return SnippetCreateInput(
            text: text,
            title: title,
            sessionTopic: sessionTopic,
            contextSummary: contextSummary,
            keywords: keywords,
            tags: tags,
            sourcePlatform: sourcePlatform,
            sourceTitle: sourceTitle,
            sourceURL: sourceURL
        )
    }

    private static func parseUpdateMetadataArguments(
        _ arguments: [String: JSONValue]
    ) throws -> (id: String, patch: SnippetMetadataPatch) {
        try rejectUnknownKeys(
            arguments,
            allowed: [
                "id",
                "title",
                "session_topic",
                "context_summary",
                "keywords",
                "add_tags",
                "remove_tags",
                "archived"
            ],
            toolName: "update_snippet_metadata"
        )
        let rawID = try parseRequiredString(arguments, key: "id")
        let id = try SnippetFilterParser.normalizeSnippetID(rawID)
        let title = try parseOptionalString(arguments, key: "title")
        let sessionTopic = try parseOptionalString(arguments, key: "session_topic")
        let contextSummary = try parseOptionalString(arguments, key: "context_summary")
        let keywords = try parseOptionalStringArray(arguments, key: "keywords").map {
            $0.flatMap(SnippetFilterParser.parseCommaSeparatedKeywords)
        }
        let addTags = try (parseOptionalStringArray(arguments, key: "add_tags") ?? [])
            .map(SnippetFilterParser.parseCustomTag)
        let removeTags = try (parseOptionalStringArray(arguments, key: "remove_tags") ?? [])
            .map(SnippetFilterParser.parseCustomTag)
        let archived = try parseOptionalBool(arguments, key: "archived")

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
            throw CLIValidationError(
                "At least one metadata field, tag update, or archived flag must be provided for update_snippet_metadata."
            )
        }
        return (id, patch)
    }

    private static func parseAppendNoteArguments(
        _ arguments: [String: JSONValue]
    ) throws -> (id: String, input: SnippetNoteInput) {
        try rejectUnknownKeys(
            arguments,
            allowed: ["id", "note", "author"],
            toolName: "append_snippet_note"
        )
        let rawID = try parseRequiredString(arguments, key: "id")
        let id = try SnippetFilterParser.normalizeSnippetID(rawID)
        let note = try parseRequiredVerbatimString(arguments, key: "note")
        let author = try parseOptionalString(arguments, key: "author")
        return (id, SnippetNoteInput(note: note, author: author))
    }

    private func makeSuccessResponse(id: JSONValue, result: JSONValue) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "result": result
        ])
    }

    private func makeErrorResponse(id: JSONValue, code: Int64, message: String) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "error": .object([
                "code": .int(code),
                "message": .string(message)
            ])
        ])
    }

    private func makeToolResultResponse(id: JSONValue, text: String, isError: Bool) -> JSONValue {
        makeSuccessResponse(
            id: id,
            result: .object([
                "content": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string(text)
                    ])
                ]),
                "isError": .bool(isError)
            ])
        )
    }

    public static let toolDefinitions: [JSONValue] = [
        .object([
            "name": .string("list_snippets"),
            "description": .string(
                "List Coding Rewind snippets with verbatim text and provenance metadata. Defaults return active snippets from the last 72h (status: \"active\", window: \"72h\", limit: 50); pass window: \"all\" (or window_hours > 72) to read older history beyond 72h, and pass status: \"synthesized\" or \"all\" to include archived #rewind/synthesized snippets."
            ),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "window": .object([
                        "type": .string("string"),
                        "description": .string("Time window such as \"72h\" (default), \"24h\", \"168h\", or \"all\" for unlimited history (>72h).")
                    ]),
                    "window_hours": .object([
                        "type": .string("number"),
                        "exclusiveMinimum": .int(0),
                        "description": .string("Numeric time window in hours (>0). Omit or pass window: \"all\" for unlimited history.")
                    ]),
                    "status": .object([
                        "type": .string("string"),
                        "enum": .array([
                            .string("active"),
                            .string("ready"),
                            .string("pending"),
                            .string("synthesized"),
                            .string("all")
                        ]),
                        "description": .string("Filter by snippet lifecycle status (default \"active\"). Pass \"synthesized\" or \"all\" for archived snippets.")
                    ]),
                    "source": .object([
                        "type": .string("string"),
                        "description": .string("Optional source platform filter (e.g. antigravity, chatgpt, claude, gemini, macos, web, agent).")
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "minimum": .int(1),
                        "maximum": .int(500),
                        "description": .string("Maximum number of snippets to return (1..500, default 50).")
                    ])
                ]),
                "required": .array([]),
                "additionalProperties": .bool(false)
            ]),
            "annotations": .object([
                "readOnlyHint": .bool(true),
                "destructiveHint": .bool(false),
                "idempotentHint": .bool(true)
            ])
        ]),
        .object([
            "name": .string("search_snippets"),
            "description": .string(
                "Search Coding Rewind snippets by case-insensitive substring across title, session topic, context summary, keywords, tags, source title, and verbatim text. Defaults search 72h active snippets (limit: 20); pass window: \"all\" or status: \"synthesized\"|\"all\" to search older (>72h) or archived history."
            ),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "minLength": .int(1),
                        "description": .string("Substring query matched across metadata headers, tags, and verbatim text.")
                    ]),
                    "window": .object([
                        "type": .string("string"),
                        "description": .string("Time window such as \"72h\" (default), \"168h\", or \"all\" for unlimited history (>72h).")
                    ]),
                    "window_hours": .object([
                        "type": .string("number"),
                        "exclusiveMinimum": .int(0),
                        "description": .string("Numeric time window in hours (>0).")
                    ]),
                    "status": .object([
                        "type": .string("string"),
                        "enum": .array([
                            .string("active"),
                            .string("ready"),
                            .string("pending"),
                            .string("synthesized"),
                            .string("all")
                        ]),
                        "description": .string("Filter by snippet lifecycle status (default \"active\"). Pass \"synthesized\" or \"all\" for archived snippets.")
                    ]),
                    "source": .object([
                        "type": .string("string"),
                        "description": .string("Optional source platform filter.")
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "minimum": .int(1),
                        "maximum": .int(500),
                        "description": .string("Maximum number of snippets to return (1..500, default 20).")
                    ])
                ]),
                "required": .array([.string("query")]),
                "additionalProperties": .bool(false)
            ]),
            "annotations": .object([
                "readOnlyHint": .bool(true),
                "destructiveHint": .bool(false),
                "idempotentHint": .bool(true)
            ])
        ]),
        .object([
            "name": .string("get_snippet"),
            "description": .string(
                "Fetch a single Coding Rewind snippet by ID (\"<id>\" or \"memos/<id>\"), returning full SnippetRecord JSON including verbatimText, metadata headers, tags, sourceURL, notes, and optional conversationContext."
            ),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object([
                        "type": .string("string"),
                        "minLength": .int(1),
                        "description": .string("Snippet ID (\"<id>\" or \"memos/<id>\").")
                    ]),
                    "include_context": .object([
                        "type": .string("boolean"),
                        "description": .string("Whether to fetch and include captured conversation context (default true).")
                    ])
                ]),
                "required": .array([.string("id")]),
                "additionalProperties": .bool(false)
            ]),
            "annotations": .object([
                "readOnlyHint": .bool(true),
                "destructiveHint": .bool(false),
                "idempotentHint": .bool(true)
            ])
        ]),
        .object([
            "name": .string("archive_snippet"),
            "description": .string(
                "Mark a Coding Rewind snippet as #rewind/synthesized on Memos while preserving 100% verbatim Markdown text intact."
            ),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object([
                        "type": .string("string"),
                        "minLength": .int(1),
                        "description": .string("Snippet ID (\"<id>\" or \"memos/<id>\") to archive.")
                    ])
                ]),
                "required": .array([.string("id")]),
                "additionalProperties": .bool(false)
            ]),
            "annotations": .object([
                "readOnlyHint": .bool(false),
                "idempotentHint": .bool(true),
                "destructiveHint": .bool(false)
            ])
        ]),
        .object([
            "name": .string("create_snippet"),
            "description": .string(
                "Create a new Coding Rewind snippet (default #source/agent) to stash a synthesized outline, draft, or highlight back into Coding Rewind with optional structured headers and custom tags."
            ),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "text": .object([
                        "type": .string("string"),
                        "minLength": .int(1),
                        "description": .string("Verbatim Markdown content to save.")
                    ]),
                    "title": .object([
                        "type": .string("string"),
                        "description": .string("Optional concise title header. Providing any metadata header emits #rewind/ready directly.")
                    ]),
                    "session_topic": .object([
                        "type": .string("string"),
                        "description": .string("Optional session or topic header.")
                    ]),
                    "context_summary": .object([
                        "type": .string("string"),
                        "description": .string("Optional 1-2 sentence context summary header.")
                    ]),
                    "keywords": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Optional topic keywords.")
                    ]),
                    "tags": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Optional custom #tag names (excluding reserved rewind/* and source/*).")
                    ]),
                    "source": .object([
                        "type": .string("string"),
                        "description": .string("Optional source platform token (default \"agent\").")
                    ]),
                    "source_title": .object([
                        "type": .string("string"),
                        "description": .string("Optional provenance display title (default \"AI Synthesis\").")
                    ]),
                    "source_url": .object([
                        "type": .string("string"),
                        "description": .string("Optional provenance link (e.g. conversation://<id> or https://...).")
                    ])
                ]),
                "required": .array([.string("text")]),
                "additionalProperties": .bool(false)
            ]),
            "annotations": .object([
                "readOnlyHint": .bool(false),
                "idempotentHint": .bool(false),
                "destructiveHint": .bool(false)
            ])
        ]),
        .object([
            "name": .string("update_snippet_metadata"),
            "description": .string(
                "Update a snippet's top metadata headers (title, session_topic, context_summary, keywords), custom tags, or archived status without modifying verbatimText."
            ),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object([
                        "type": .string("string"),
                        "minLength": .int(1),
                        "description": .string("Snippet ID (\"<id>\" or \"memos/<id>\").")
                    ]),
                    "title": .object([
                        "type": .string("string"),
                        "description": .string("Updated title header (pass empty string to clear).")
                    ]),
                    "session_topic": .object([
                        "type": .string("string"),
                        "description": .string("Updated session topic header (pass empty string to clear).")
                    ]),
                    "context_summary": .object([
                        "type": .string("string"),
                        "description": .string("Updated context summary header (pass empty string to clear).")
                    ]),
                    "keywords": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Replacement keywords list.")
                    ]),
                    "add_tags": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Custom tags to add to line 1.")
                    ]),
                    "remove_tags": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Custom tags to remove from line 1.")
                    ]),
                    "archived": .object([
                        "type": .string("boolean"),
                        "description": .string("true marks #rewind/synthesized; false unarchives back to active (#rewind/ready or #rewind/pending).")
                    ])
                ]),
                "required": .array([.string("id")]),
                "additionalProperties": .bool(false)
            ]),
            "annotations": .object([
                "readOnlyHint": .bool(false),
                "idempotentHint": .bool(true),
                "destructiveHint": .bool(false)
            ])
        ]),
        .object([
            "name": .string("append_snippet_note"),
            "description": .string(
                "Attach a private Markdown note/conclusion (<!-- rewind-note-v1 -->) to an existing snippet by ID while keeping verbatimText untouched."
            ),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object([
                        "type": .string("string"),
                        "minLength": .int(1),
                        "description": .string("Target snippet ID (\"<id>\" or \"memos/<id>\").")
                    ]),
                    "note": .object([
                        "type": .string("string"),
                        "minLength": .int(1),
                        "description": .string("Markdown note or conclusion to attach.")
                    ]),
                    "author": .object([
                        "type": .string("string"),
                        "description": .string("Optional single-line author label (default \"agent\").")
                    ])
                ]),
                "required": .array([.string("id"), .string("note")]),
                "additionalProperties": .bool(false)
            ]),
            "annotations": .object([
                "readOnlyHint": .bool(false),
                "idempotentHint": .bool(false),
                "destructiveHint": .bool(false)
            ])
        ])
    ]
}
