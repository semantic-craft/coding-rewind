// SPDX-License-Identifier: MIT

import Foundation

public struct RewindMCPServer: Sendable {
    public let stash: StashStore

    public init(stash: StashStore) {
        self.stash = stash
    }

    public func serve(input: FileHandle, output: FileHandle) async throws {
        var buffer = Data()

        while true {
            guard let chunk = try input.read(upToCount: 4096), !chunk.isEmpty else {
                break
            }
            buffer.append(chunk)

            while let extracted = Self.extractNextFrame(from: &buffer) {
                if let responseData = await handleMessage(extracted.payload) {
                    switch extracted.framing {
                    case .newlineDelimited:
                        var lineOut = responseData
                        if lineOut.last != UInt8(ascii: "\n") {
                            lineOut.append(UInt8(ascii: "\n"))
                        }
                        output.write(lineOut)
                    case .contentLength:
                        let header = "Content-Length: \(responseData.count)\r\n\r\n"
                        output.write(Data(header.utf8))
                        output.write(responseData)
                    }
                }
            }
        }
    }

    public func handleMessage(_ messageData: Data, now: Date = Date()) async -> Data? {
        guard let root = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any] else {
            return encodeError(id: NSNull(), code: -32700, message: "Parse error")
        }

        let method = root["method"] as? String ?? ""
        let hasID = root.keys.contains("id")
        let requestID: Any = root["id"] ?? NSNull()

        if !hasID || method.hasPrefix("notifications/") {
            return nil
        }

        switch method {
        case "initialize":
            let result: [String: Any] = [
                "protocolVersion": "2024-11-05",
                "capabilities": [
                    "tools": [
                        "listChanged": false
                    ]
                ],
                "serverInfo": [
                    "name": "coding-rewind-mcp",
                    "version": "0.1.0"
                ]
            ]
            return encodeResult(id: requestID, result: result)

        case "ping":
            return encodeResult(id: requestID, result: [:] as [String: Any])

        case "tools/list":
            let tools: [[String: Any]] = RewindMCPToolID.allCases.map { Self.toolDefinition(for: $0) }
            return encodeResult(id: requestID, result: ["tools": tools])

        case "tools/call":
            guard let params = root["params"] as? [String: Any],
                  let toolName = params["name"] as? String,
                  let toolID = RewindMCPToolID(rawValue: toolName) else {
                return encodeError(id: requestID, code: -32602, message: "Unknown or missing MCP tool name")
            }
            let arguments = (params["arguments"] as? [String: Any]) ?? [:]
            return await executeToolCall(id: requestID, toolID: toolID, arguments: arguments, now: now)

        default:
            return encodeError(id: requestID, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func executeToolCall(
        id: Any,
        toolID: RewindMCPToolID,
        arguments: [String: Any],
        now: Date
    ) async -> Data? {
        do {
            switch toolID {
            case .listHotClips:
                let limit = (arguments["limit"] as? Int) ?? 25
                let includeArchived = (arguments["include_archived"] as? Bool) ?? false
                let scope: ClipScope = includeArchived ? .all : .hot
                let clips = try await stash.clips(
                    matching: ClipQuery(text: nil, scope: scope, limit: limit, referenceDate: now)
                )
                return encodeToolSuccess(id: id, payload: serializeClipsPayload(clips, now: now))

            case .searchClips:
                let rawQuery = (arguments["query"] as? String)
                    ?? (arguments["query_text"] as? String)
                    ?? ""
                let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    return encodeToolError(id: id, message: "Missing required argument: query")
                }
                let limit = (arguments["limit"] as? Int) ?? 20
                let hotOnly = (arguments["hot_only"] as? Bool) ?? false
                let scope: ClipScope = hotOnly ? .hot : .all
                let clips = try await stash.clips(
                    matching: ClipQuery(text: trimmed, scope: scope, limit: limit, referenceDate: now)
                )
                return encodeToolSuccess(id: id, payload: serializeClipsPayload(clips, now: now))

            case .getClip:
                guard let rawClipID = arguments["clip_id"] as? String,
                      let clipID = try? ClipID(parsing: rawClipID) else {
                    return encodeToolError(id: id, message: "Invalid or missing required argument: clip_id")
                }
                guard let clip = try await stash.clip(id: clipID) else {
                    return encodeToolError(id: id, message: "Clip not found: \(clipID.rawValue)")
                }
                return encodeToolSuccess(id: id, payload: serializeClipRecord(clip, now: now))
            }
        } catch {
            return encodeToolError(id: id, message: error.localizedDescription)
        }
    }

    private func serializeClipsPayload(_ clips: [Clip], now: Date) -> [String: Any] {
        [
            "count": clips.count,
            "clips": clips.map { serializeClipRecord($0, now: now) }
        ]
    }

    private func serializeClipRecord(_ clip: Clip, now: Date) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        var dict: [String: Any] = [
            "clip_id": clip.id.rawValue,
            "short_code": clip.id.shortCode,
            "excerpt": clip.excerpt,
            "prompt_status": clip.promptContext == .missing ? "missing" : "captured",
            "prompt_context": clip.promptContext.capturedText ?? NSNull(),
            "source_badge": clip.source.displayBadge,
            "reopen_url": clip.source.reopenURL?.absoluteString ?? NSNull(),
            "captured_at": iso.string(from: clip.capturedAt),
            "lifecycle": clip.lifecycle(at: now).rawValue,
            "annotation_title": clip.annotation.title ?? NSNull(),
            "annotation_tags": clip.annotation.tags,
            "annotation_user_note": clip.annotation.userNote ?? NSNull()
        ]
        switch clip.source {
        case .antigravity(let conversationId, let workspacePath, let locator):
            dict["source_kind"] = "antigravity"
            dict["conversation_id"] = conversationId ?? NSNull()
            dict["workspace_path"] = workspacePath ?? NSNull()
            dict["locator"] = locator ?? NSNull()
        case .web(let site, let url, let pageTitle):
            dict["source_kind"] = "web"
            dict["web_site"] = site.rawValue
            dict["web_url"] = url ?? NSNull()
            dict["page_title"] = pageTitle ?? NSNull()
        case .desktop(let bundleIdentifier, let appName, let windowTitle):
            dict["source_kind"] = "desktop"
            dict["bundle_identifier"] = bundleIdentifier
            dict["app_name"] = appName
            dict["window_title"] = windowTitle ?? NSNull()
        }
        return dict
    }

    private static func toolDefinition(for toolID: RewindMCPToolID) -> [String: Any] {
        switch toolID {
        case .listHotClips:
            return [
                "name": toolID.rawValue,
                "description": toolID.summaryDescription,
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "limit": [
                            "type": "integer",
                            "description": "Maximum number of clips to return (default 25)."
                        ],
                        "include_archived": [
                            "type": "boolean",
                            "description": "When true, include clips older than 72 hours or already synthesized."
                        ]
                    ]
                ]
            ]
        case .searchClips:
            return [
                "name": toolID.rawValue,
                "description": toolID.summaryDescription,
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": "Natural-language search phrase in Chinese or English."
                        ],
                        "limit": [
                            "type": "integer",
                            "description": "Maximum number of matching clips to return (default 20)."
                        ],
                        "hot_only": [
                            "type": "boolean",
                            "description": "When true, restrict matches to the 72-hour hot window."
                        ]
                    ],
                    "required": ["query"]
                ]
            ]
        case .getClip:
            return [
                "name": toolID.rawValue,
                "description": toolID.summaryDescription,
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "clip_id": [
                            "type": "string",
                            "description": "Exact clip_id UUID returned by rewind_list_hot_clips or rewind_search_clips."
                        ]
                    ],
                    "required": ["clip_id"]
                ]
            ]
        }
    }

    private func encodeToolSuccess(id: Any, payload: [String: Any]) -> Data? {
        let prettyData = (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
        let text = String(decoding: prettyData, as: UTF8.self)
        return encodeResult(
            id: id,
            result: [
                "content": [
                    [
                        "type": "text",
                        "text": text
                    ]
                ],
                "isError": false
            ]
        )
    }

    private func encodeToolError(id: Any, message: String) -> Data? {
        encodeResult(
            id: id,
            result: [
                "content": [
                    [
                        "type": "text",
                        "text": message
                    ]
                ],
                "isError": true
            ]
        )
    }

    private func encodeResult(id: Any, result: [String: Any]) -> Data? {
        let envelope: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": result
        ]
        return try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
    }

    private func encodeError(id: Any, code: Int, message: String) -> Data? {
        let envelope: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "error": [
                "code": code,
                "message": message
            ]
        ]
        return try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
    }

    private enum Framing {
        case newlineDelimited
        case contentLength
    }

    private static func extractNextFrame(from buffer: inout Data) -> (payload: Data, framing: Framing)? {
        while let firstByte = buffer.first, firstByte == UInt8(ascii: "\r") || firstByte == UInt8(ascii: "\n") {
            buffer.removeFirst()
        }
        guard !buffer.isEmpty else { return nil }

        let contentLengthPrefix = Data("Content-Length:".utf8)
        let lowerPrefix = Data("content-length:".utf8)
        if buffer.starts(with: contentLengthPrefix) || buffer.starts(with: lowerPrefix) {
            let separatorCRLF = Data("\r\n\r\n".utf8)
            let separatorLF = Data("\n\n".utf8)

            let headerEndRange = buffer.range(of: separatorCRLF) ?? buffer.range(of: separatorLF)
            guard let headerRange = headerEndRange else {
                return nil
            }
            let headerData = buffer.subdata(in: 0..<headerRange.lowerBound)
            let headerString = String(decoding: headerData, as: UTF8.self)
            var declaredLength: Int?
            for line in headerString.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                    declaredLength = Int(parts[1].trimmingCharacters(in: .whitespaces))
                }
            }
            guard let contentLength = declaredLength, contentLength >= 0 else {
                buffer.removeSubrange(0..<headerRange.upperBound)
                return nil
            }
            let totalNeeded = headerRange.upperBound + contentLength
            guard buffer.count >= totalNeeded else {
                return nil
            }
            let payload = buffer.subdata(in: headerRange.upperBound..<totalNeeded)
            buffer.removeSubrange(0..<totalNeeded)
            return (payload, .contentLength)
        }

        if let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            var lineData = buffer.subdata(in: 0..<newlineIndex)
            if lineData.last == UInt8(ascii: "\r") {
                lineData.removeLast()
            }
            buffer.removeSubrange(0...newlineIndex)
            if lineData.isEmpty {
                return nil
            }
            return (lineData, .newlineDelimited)
        }

        return nil
    }
}
