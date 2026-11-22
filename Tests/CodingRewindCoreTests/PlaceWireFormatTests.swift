// SPDX-License-Identifier: MIT

@testable import CodingRewindCore
import Foundation
import Testing

@Suite("Places: slug validation, tag parsing, place memo wire format")
struct PlaceWireFormatTests {
    @Test("PlaceSlug accepts kebab-case up to 28 chars and rejects everything else")
    func slugValidation() {
        #expect(PlaceSlug("paper-02")?.rawValue == "paper-02")
        #expect(PlaceSlug(String(repeating: "a", count: 28)) != nil)
        for invalid in ["", "-a", "a-", "a--b", "Paper", "论文", "a_b", "a/b", String(repeating: "a", count: 29)] {
            #expect(PlaceSlug(invalid) == nil, "\(invalid) should be rejected")
        }
    }

    @Test("PlaceRef parses known kinds case-insensitively and derives a valid memoId")
    func refParsingAndMemoID() throws {
        let ref = try #require(PlaceRef(tag: "#Project/Paper-02"))
        #expect(ref.kind == .project)
        #expect(ref.slug.rawValue == "paper-02")
        #expect(ref.tag == "project/paper-02")
        #expect(PlaceRef(tag: "topic/embodiment")?.memoID == "pl-t-embodiment")
        #expect(PlaceRef(tag: "person/ada")?.memoID == "pl-u-ada")
        #expect(ref.memoID == "pl-p-paper-02")
        let longest = try #require(PlaceRef(tag: "project/" + String(repeating: "z", count: 28)))
        #expect(MemosWireFormat.isValidMemoID(longest.memoID))
        #expect(PlaceRef(tag: "habit/run") == nil)
        #expect(PlaceRef(tag: "project/bad_slug") == nil)
        #expect(PlaceRef(tag: "project/a/b") == nil)
    }

    @Test("snippet header place tags become places while unknown kinds stay ordinary custom tags")
    func snippetPlacesFromHeader() throws {
        let verbatim = "Body mentions #project/not-a-header-tag and keeps\n\n  whitespace 汉字\n"
        let raw = "#rewind/ready #source/web #Project/Paper-02 #habit/run #project/bad_slug #topic/embodiment #project/paper-02\n\n> **Title:** T\n\n" + verbatim
        let record = try #require(MemosWireFormat.parseSnippetRecord(id: "rw-1", rawContent: raw, createdAt: Date(), dataOrigin: .remote))
        #expect(record.places.map(\.tag) == ["project/paper-02", "topic/embodiment"])
        #expect(record.tags.contains("habit/run"))
        #expect(record.tags.contains("project/bad_slug"))
        #expect(record.verbatimText == verbatim)

        let card = try #require(MemosWireFormat.parseMemo(id: "rw-1", rawContent: raw, createdAt: Date()))
        #expect(card.places == record.places)
    }

    @Test("adding and removing a place tag leaves the verbatim body byte-identical")
    func placeTagRoundTripPreservesBody() throws {
        let verbatim = "```swift\nlet x = 1\n\n\n```\n#project/paper-02 in body\r\ntrailing  \n"
        let raw = "#rewind/ready #source/web\n\n> **Title:** T\n> **Source:** [S](https://example.com) · 2026-11-20T00:00:00Z\n\n" + verbatim
        let added = MemosWireFormat.updatingSnippetMetadata(rawContent: raw, addTags: ["project/paper-02"])
        let addedRecord = try #require(MemosWireFormat.parseSnippetRecord(id: "a", rawContent: added, createdAt: Date(), dataOrigin: .remote))
        #expect(addedRecord.places.map(\.tag) == ["project/paper-02"])
        #expect(Data(addedRecord.verbatimText.utf8) == Data(verbatim.utf8))

        let removed = MemosWireFormat.updatingSnippetMetadata(rawContent: added, removeTags: ["Project/Paper-02"])
        let removedRecord = try #require(MemosWireFormat.parseSnippetRecord(id: "a", rawContent: removed, createdAt: Date(), dataOrigin: .remote))
        #expect(removedRecord.places.isEmpty)
        #expect(Data(removed.utf8) == Data(raw.utf8))
    }

    @Test("place memo formats to the fixed wire layout and round-trips with a byte-identical body")
    func placeMemoRoundTrip() throws {
        let ref = try #require(PlaceRef(tag: "project/paper-02"))
        let place = PlaceRecord(ref: ref, title: "著作权法的身体预设", aliases: ["论文02", "身体预设", "embodiment"], externalRef: "Linear XWR-12")
        let body = "\n## 位置页\n\n- 保留\t制表符\r\n  与空行\n\n"
        let formatted = MemosWireFormat.formatPlaceMemo(place, body: body)
        #expect(formatted == """
            #rewind/place #project/paper-02

            > **Title:** 著作权法的身体预设
            > **Aliases:** 论文02, 身体预设, embodiment
            > **Ref:** Linear XWR-12
            > **Status:** active
            """ + "\n\n" + body)

        let parsed = try #require(MemosWireFormat.parsePlaceMemo(formatted))
        #expect(parsed.place == place)
        #expect(Data(parsed.body.utf8) == Data(body.utf8))

        var archived = place
        archived.externalRef = nil
        archived.archived = true
        let archivedMemo = MemosWireFormat.formatPlaceMemo(archived)
        #expect(!archivedMemo.contains("**Ref:**"))
        #expect(archivedMemo.hasSuffix("> **Status:** archived"))
        #expect(MemosWireFormat.parsePlaceMemo(archivedMemo)?.place == archived)
    }

    @Test("place memos are never parsed as snippets and snippets are never parsed as places")
    func placeAndSnippetMemosStaySeparate() {
        let placeMemo = MemosWireFormat.formatPlaceMemo(PlaceRecord(ref: PlaceRef(tag: "topic/x")!, title: "X"))
        #expect(MemosWireFormat.parseSnippetRecord(id: "pl-t-x", rawContent: placeMemo, createdAt: Date(), dataOrigin: .remote) == nil)
        #expect(MemosWireFormat.parsePlaceMemo("#rewind/ready #source/web #topic/x\n\nbody") == nil)
        #expect(MemosWireFormat.parsePlaceMemo("#rewind/place\n\n> **Title:** no ref") == nil)
    }

    @Test("fuzzy matching ranks prefix over substring over subsequence across title, aliases and tag")
    func fuzzyMatching() throws {
        let paper = PlaceRecord(ref: PlaceRef(tag: "project/paper-02")!, title: "著作权法的身体预设", aliases: ["论文02", "embodiment"])
        let body = PlaceRecord(ref: PlaceRef(tag: "topic/body")!, title: "Body Studies")
        let ada = PlaceRecord(ref: PlaceRef(tag: "person/ada")!, title: "Ada Lovelace")
        let all = [paper, body, ada]
        #expect(PlaceRecord.fuzzyMatches("", in: all).map(\.ref.tag) == ["project/paper-02", "topic/body", "person/ada"])
        #expect(PlaceRecord.fuzzyMatches("bod", in: all).map(\.ref.tag) == ["topic/body", "project/paper-02"])
        #expect(PlaceRecord.fuzzyMatches("身体", in: all).map(\.ref.tag) == ["project/paper-02"])
        #expect(PlaceRecord.fuzzyMatches("alv", in: all).map(\.ref.tag) == ["person/ada"])
        #expect(PlaceRecord.fuzzyMatches("qqq", in: all).isEmpty)
        #expect(body.fuzzyScore("bod") == .prefix)
        #expect(paper.fuzzyScore("bod") == .substring)
        #expect(ada.fuzzyScore("alv") == .subsequence)
        #expect(ada.fuzzyScore("qqq") == nil)
        #expect(PlaceMatchRank.prefix < .substring && PlaceMatchRank.substring < .subsequence)
    }

    @Test("unplaced is derived from ready or synthesized status with no place tags")
    func unplacedDerivation() throws {
        func record(_ header: String) throws -> SnippetRecord {
            try #require(MemosWireFormat.parseSnippetRecord(id: "r", rawContent: header + "\n\nbody", createdAt: Date(), dataOrigin: .remote))
        }
        #expect(try record("#rewind/ready #source/web").isUnplaced)
        #expect(try record("#rewind/synthesized #source/web #habit/run").isUnplaced)
        #expect(try !record("#rewind/pending #source/web").isUnplaced)
        #expect(try !record("#rewind/ready #source/web #person/ada").isUnplaced)
    }
}
