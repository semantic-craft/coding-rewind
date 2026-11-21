// SPDX-License-Identifier: MIT

@testable import CodingRewindCLI
import CodingRewindCore
import Foundation
import Testing

private final class LockedMemoMap: @unchecked Sendable {
    private let lock = NSLock()
    private var contents: [String: String] = [:]

    func get(_ id: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return contents[id]
    }

    func set(_ id: String, _ content: String) {
        lock.lock()
        contents[id] = content
        lock.unlock()
    }

    func all() -> [(String, String)] {
        lock.lock()
        defer { lock.unlock() }
        return contents.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }
}

@Suite("CLI places: place list/add and list --place/--unplaced")
struct PlaceCLITests {
    @Test("parser accepts place subcommands and place filters and rejects malformed input")
    func parsesPlaceCommands() throws {
        #expect(try CLIParser.parse(arguments: ["coding-rewind", "place", "list"]) == .placeList(includeArchived: false, dataDir: nil, json: false))
        #expect(try CLIParser.parse(arguments: ["coding-rewind", "place", "list", "--all", "--json"]) == .placeList(includeArchived: true, dataDir: nil, json: true))

        let add = try CLIParser.parse(arguments: [
            "coding-rewind", "place", "add", "--kind", "Project", "--slug", "paper-02", "--title", "身体预设",
            "--alias", "论文02", "--alias=embodiment", "--ref", "Linear XWR-12", "--archived", "--json"
        ])
        let ref = try #require(PlaceRef(tag: "project/paper-02"))
        #expect(add == .placeAdd(
            place: PlaceRecord(ref: ref, title: "身体预设", aliases: ["论文02", "embodiment"], externalRef: "Linear XWR-12", archived: true),
            dataDir: nil,
            json: true
        ))

        #expect(try CLIParser.parse(arguments: ["coding-rewind", "list", "--window", "all", "--place", "#Project/Paper-02"]) == .list(
            query: SnippetQuery(windowHours: nil, place: ref),
            dataDir: nil,
            json: false
        ))
        #expect(try CLIParser.parse(arguments: ["coding-rewind", "search", "q", "--unplaced", "--status", "all"]) == .search(
            query: SnippetQuery(status: .all, searchText: "q", unplaced: true),
            dataDir: nil,
            json: false
        ))
        #expect(CLIParser.usageText.contains("coding-rewind place add --kind <project|topic|person> --slug <slug> --title <t>"))
        #expect(CLIParser.usageText.contains("[--place <kind>/<slug> | --unplaced]"))

        for bad in [
            ["coding-rewind", "place"],
            ["coding-rewind", "place", "remove"],
            ["coding-rewind", "place", "list", "--archived"],
            ["coding-rewind", "place", "add", "--slug", "x", "--title", "X"],
            ["coding-rewind", "place", "add", "--kind", "habit", "--slug", "x", "--title", "X"],
            ["coding-rewind", "place", "add", "--kind", "topic", "--slug", "Bad_Slug", "--title", "X"],
            ["coding-rewind", "place", "add", "--kind", "topic", "--slug", "x"],
            ["coding-rewind", "list", "--place", "habit/run"],
            ["coding-rewind", "list", "--place", "project/x", "--unplaced"],
            ["coding-rewind", "list", "--unplaced=yes"]
        ] {
            #expect(throws: CLIValidationError.self, "\(bad)") {
                _ = try CLIParser.parse(arguments: bad)
            }
        }
    }

    @Test("runner forwards place filters and prints stable place JSON")
    func runnerPlaceJSON() async throws {
        let dir = try SnippetCLIFixtures.makeIsolatedDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let backend = FakeSnippetBackend(records: SnippetCLIFixtures.makeSampleRecords())
        let ref = try #require(PlaceRef(tag: "topic/embodiment"))
        await backend.seedPlaces([
            PlaceRecord(ref: ref, title: "Embodiment", aliases: ["身体"]),
            PlaceRecord(ref: PlaceRef(tag: "person/old")!, title: "Old", archived: true)
        ])

        func run(_ args: [String]) async -> (Int32, String, String) {
            let out = OutputCollector()
            let err = OutputCollector()
            let code = await CLIRunner.run(
                arguments: ["coding-rewind"] + args + ["--data-dir", dir.path],
                environment: [:],
                now: { SnippetCLIFixtures.fixedNow },
                writeStdout: out.append,
                writeStderr: err.append,
                repositoryFactory: { _, _, _ in backend }
            )
            return (code, out.value(), err.value())
        }

        let (listCode, listOut, _) = await run(["place", "list", "--json"])
        #expect(listCode == 0)
        let listed = try JSONSerialization.jsonObject(with: Data(listOut.utf8)) as! [String: Any]
        let places = listed["places"] as! [[String: Any]]
        #expect(places.count == 1)
        #expect(places[0]["title"] as? String == "Embodiment")
        #expect(places[0]["ref"] as? [String: String] == ["kind": "topic", "slug": "embodiment"])
        #expect(places[0]["aliases"] as? [String] == ["身体"])
        #expect(places[0]["archived"] as? Bool == false)
        #expect(listed["resolution"] != nil)

        let (allCode, allOut, _) = await run(["place", "list", "--all"])
        #expect(allCode == 0)
        #expect(allOut.contains("- #topic/embodiment Embodiment · aliases: 身体"))
        #expect(allOut.contains("- #person/old Old · archived"))

        let (addCode, addOut, _) = await run(["place", "add", "--kind", "project", "--slug", "paper-02", "--title", "P", "--json"])
        #expect(addCode == 0)
        let added = try JSONSerialization.jsonObject(with: Data(addOut.utf8)) as! [String: Any]
        #expect(added["ref"] as? [String: String] == ["kind": "project", "slug": "paper-02"])
        #expect(await backend.recordedUpsertPlaces.map(\.ref.tag) == ["project/paper-02"])

        _ = await run(["list", "--place", "topic/embodiment", "--window", "all"])
        _ = await run(["list", "--unplaced"])
        let queries = await backend.recordedListQueries
        #expect(queries.map(\.place) == [ref, nil])
        #expect(queries.map(\.unplaced) == [false, true])

        let (getCode, getOut, _) = await run(["get", "rw-recent-ready", "--json"])
        #expect(getCode == 0)
        #expect((try JSONSerialization.jsonObject(with: Data(getOut.utf8)) as! [String: Any])["places"] as? [Any] != nil)
    }

    @Test("place add against a real Memos endpoint is idempotent, keeps the free body, and fails clearly offline")
    func placeAddEndToEnd() async throws {
        let dir = try SnippetCLIFixtures.makeIsolatedDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let memos = LockedMemoMap()
        let server = try LoopbackMemosHTTPServer { request in
            let components = URLComponents(string: request.target)!
            let reply: (String, String) -> (Int, Data) = { id, content in
                (200, try! JSONSerialization.data(withJSONObject: ["name": "memos/\(id)", "content": content, "createTime": "2026-11-15T00:00:00Z"]))
            }
            let bodyContent = { (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any])?["content"] as? String ?? "" }
            switch (request.method, components.path) {
            case ("GET", "/api/memos"):
                let list = memos.all().map { ["name": "memos/\($0.0)", "content": $0.1, "createTime": "2026-11-15T00:00:00Z"] }
                return (200, try! JSONSerialization.data(withJSONObject: ["memos": list, "nextPageToken": ""]))
            case ("POST", "/api/memos"):
                let id = components.queryItems!.first { $0.name == "memoId" }!.value!
                if memos.get(id) != nil { return (409, Data("{}".utf8)) }
                memos.set(id, bodyContent())
                return reply(id, bodyContent())
            case ("GET", let path):
                let id = String(path.dropFirst("/api/memos/".count))
                guard let content = memos.get(id) else { return (404, Data("{}".utf8)) }
                return reply(id, content)
            case ("PATCH", let path):
                let id = String(path.dropFirst("/api/memos/".count))
                memos.set(id, bodyContent())
                return reply(id, bodyContent())
            default:
                return (400, Data("{}".utf8))
            }
        }
        defer { server.shutdown() }

        let env = [
            StoragePaths.memosURLEnvironmentKey: server.baseURLString,
            StoragePaths.memosTokenEnvironmentKey: "token",
            StoragePaths.qaEnvironmentKey: "1"
        ]
        func run(_ args: [String], environment: [String: String]) async -> (Int32, String, String) {
            let out = OutputCollector()
            let err = OutputCollector()
            let code = await CLIRunner.run(
                arguments: ["coding-rewind"] + args + ["--data-dir", dir.path],
                environment: environment,
                now: { SnippetCLIFixtures.fixedNow },
                writeStdout: out.append,
                writeStderr: err.append
            )
            return (code, out.value(), err.value())
        }

        let addArgs = ["place", "add", "--kind", "project", "--slug", "paper-02", "--title", "身体预设", "--alias", "论文02", "--json"]
        let (firstCode, firstOut, firstErr) = await run(addArgs, environment: env)
        #expect(firstCode == 0, "\(firstErr)")
        let firstMemo = try #require(memos.get("pl-p-paper-02"))
        let body = "位置页正文\n\n  保留\n"
        memos.set("pl-p-paper-02", firstMemo + "\n\n" + body)

        let (secondCode, secondOut, _) = await run(addArgs, environment: env)
        #expect(secondCode == 0)
        #expect(secondOut == firstOut)
        #expect(memos.get("pl-p-paper-02") == firstMemo + "\n\n" + body)
        #expect(memos.all().count == 1)

        let (listCode, listOut, _) = await run(["place", "list"], environment: env)
        #expect(listCode == 0)
        #expect(listOut.contains("- #project/paper-02 身体预设 · aliases: 论文02"))

        server.shutdown()
        let (offlineAddCode, offlineAddOut, offlineAddErr) = await run(addArgs, environment: env)
        #expect(offlineAddCode == 1)
        #expect(offlineAddOut.isEmpty)
        #expect(offlineAddErr.hasPrefix("Error: "))
        let (offlineListCode, offlineListOut, _) = await run(["place", "list"], environment: env)
        #expect(offlineListCode == 0)
        #expect(offlineListOut.contains("offlineFallback"))
        #expect(offlineListOut.contains("- #project/paper-02 身体预设"))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("outbox.jsonl").path))
    }
}
