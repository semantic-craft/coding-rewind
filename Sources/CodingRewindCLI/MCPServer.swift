// SPDX-License-Identifier: MIT

import CodingRewindCore
import Darwin
import Foundation

public struct MCPServer: Sendable {
    public static let serverName = "coding-rewind"
    public static let serverVersion = CLIParser.versionString
    public static let defaultProtocolVersion = "2024-11-05"
    public static let supportedProtocolVersions: Set<String> = [
        "2024-11-05",
        "2025-03-26",
        "2025-06-18"
    ]

    private let repositoryProvider: @Sendable () throws -> any SnippetQuerying
    private let now: @Sendable () -> Date

    public init(
        repositoryProvider: @escaping @Sendable () throws -> any SnippetQuerying,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.repositoryProvider = repositoryProvider
        self.now = now
    }

    public func run(inputFD: Int32 = STDIN_FILENO, outputFD: Int32 = STDOUT_FILENO) async -> Int32 {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)

        while true {
            let bytesRead = Darwin.read(inputFD, &chunk, chunk.count)
            if bytesRead < 0 {
                if errno == EINTR { continue }
                return 1
            }
            if bytesRead == 0 {
                if !buffer.isEmpty {
                    await processLineData(buffer, outputFD: outputFD)
                    buffer.removeAll()
                }
                return 0
            }

            buffer.append(chunk, count: bytesRead)
            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = Data(buffer[..<newlineIndex])
                buffer.removeSubrange(...newlineIndex)
                await processLineData(lineData, outputFD: outputFD)
            }
        }
    }

    public func handleLine(_ lineData: Data) async -> Data? {
        var trimmed = lineData
        while let last = trimmed.last, last == 0x0D || last == 0x0A {
            trimmed.removeLast()
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

    private func processLineData(_ lineData: Data, outputFD: Int32) async {
        guard let responseData = await handleLine(lineData) else { return }
        writeAll(responseData, to: outputFD)
    }

    private func writeAll(_ data: Data, to fd: Int32) {
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            var offset = 0
            while remaining > 0 {
                let written = Darwin.write(fd, base.advanced(by: offset), remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    return
                }
                remaining -= written
                offset += written
            }
        }
    }

    private func handleMessageObject(_ object: [String: JSONValue]) async -> JSONValue? {
        let hasID = object.keys.contains("id")
        let requestID = object["id"] ?? .null

        guard case .string(let jsonrpc) = object["jsonrpc"], jsonrpc == "2.0",
              case .string(let method) = object["method"], !method.isEmpty else {
            guard hasID else { return nil }
            return makeErrorResponse(id: requestID, code: -32600, message: "Invalid Request")
        }

        switch requestID {
        case .string, .int, .double, .null:
            break
        case .bool, .array, .object:
            return makeErrorResponse(id: .null, code: -32600, message: "Invalid Request: invalid id type")
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
            let repository = try repositoryProvider()
            switch name {
            case "list_snippets":
                let query = try Self.parseListArguments(arguments)
                let result = try await repository.listSnippets(query, now: now())
                let json = try SnippetFormatter.encodePrettyJSON(result)
                return (json, false)

            case "search_snippets":
                let query = try Self.parseSearchArguments(arguments)
                let result = try await repository.listSnippets(query, now: now())
                let json = try SnippetFormatter.encodePrettyJSON(result)
                return (json, false)

            case "get_snippet":
                let (id, includeContext) = try Self.parseGetArguments(arguments)
                let record = try await repository.getSnippet(id: id, includeContext: includeContext, now: now())
                let json = try SnippetFormatter.encodePrettyJSON(record)
                return (json, false)

            case "archive_snippet":
                let id = try Self.parseArchiveArguments(arguments)
                let record = try await repository.archiveSnippet(id: id)
                let json = try SnippetFormatter.encodePrettyJSON(record)
                return (json, false)

            default:
                return ("Unknown tool '\(name)'. Supported tools: list_snippets, search_snippets, get_snippet, archive_snippet.", true)
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
        if let windowString, let windowHoursNumber {
            let parsedWindow = try SnippetFilterParser.parseWindow(windowString)
            let validatedHours = try SnippetFilterParser.validateWindowHours(windowHoursNumber)
            guard parsedWindow != nil else {
                throw CLIValidationError("Cannot combine window: \"all\" with window_hours.")
            }
            return validatedHours
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
                        "description": .string("Optional source platform filter (e.g. antigravity, chatgpt, claude, gemini, macos, web).")
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
                "Search Coding Rewind snippets by case-insensitive substring across title, session topic, context summary, keywords, source title, and verbatim text. Defaults search 72h active snippets (limit: 20); pass window: \"all\" or status: \"synthesized\"|\"all\" to search older (>72h) or archived history."
            ),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "minLength": .int(1),
                        "description": .string("Substring query matched across metadata headers and verbatim text.")
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
                "Fetch a single Coding Rewind snippet by ID (\"<id>\" or \"memos/<id>\"), returning full SnippetRecord JSON including verbatimText, metadata headers, sourceURL, and optional conversationContext."
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
        ])
    ]
}
