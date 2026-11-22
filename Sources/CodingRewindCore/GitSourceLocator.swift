// SPDX-License-Identifier: MIT

import Foundation

public struct GitSourceRequest: Equatable, Sendable {
    public struct ValidationError: LocalizedError, Sendable {
        public let errorDescription: String?

        fileprivate init(_ message: String) {
            errorDescription = message
        }
    }

    private enum Forge: String {
        case github = "github.com"
        case gitlab = "gitlab.com"

        var blobPath: String {
            switch self {
            case .github: "blob"
            case .gitlab: "-/blob"
            }
        }

        func lineFragment(_ lines: ClosedRange<Int>) -> String {
            let start = "L\(lines.lowerBound)"
            guard lines.lowerBound != lines.upperBound else { return start }
            return "\(start)-\(self == .github ? "L" : "")\(lines.upperBound)"
        }
    }

    private let file: String
    private let root: String?
    private let commit: String?
    private let lineRange: ClosedRange<Int>?

    public init(file: String, root: String? = nil, commit: String? = nil, lines: String? = nil) throws {
        let segments = file.split(separator: "/", omittingEmptySubsequences: false)
        guard !file.isEmpty, file.utf8.count <= 4096,
              file.rangeOfCharacter(from: .controlCharacters) == nil,
              !file.contains("\\"),
              segments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ValidationError("'--git-file' requires a path relative to the repository root.")
        }
        if let root, root.isEmpty || root.rangeOfCharacter(from: .controlCharacters) != nil {
            throw ValidationError("'--git-root' requires a checkout directory.")
        }
        if let commit, !Self.isObjectID(commit) {
            throw ValidationError("'--git-commit' requires a full commit ID.")
        }
        if let lines {
            let bounds = lines.split(separator: "-", omittingEmptySubsequences: false)
            guard (1...2).contains(bounds.count),
                  bounds.allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }),
                  let lower = bounds.first.flatMap({ Int($0) }),
                  let upper = bounds.last.flatMap({ Int($0) }),
                  lower > 0, upper >= lower else {
                throw ValidationError("'--git-lines' requires a positive line or an inclusive range such as 12-18.")
            }
            lineRange = lower...upper
        } else {
            lineRange = nil
        }
        self.file = file
        self.root = root
        self.commit = commit
    }

    public func resolve() throws -> (title: String, url: URL) {
        let revision = commit ?? "HEAD"
        let rawCommit = try git(["rev-parse", "--verify", "\(revision)^{commit}"],
                                failure: "Could not resolve a local Git commit. Run inside a checkout or pass '--git-root'.")
        let commitID = String(decoding: rawCommit, as: UTF8.self).trimmingCharacters(in: .newlines)
        guard Self.isObjectID(commitID), commit == nil || commitID == revision.lowercased() else {
            throw ValidationError("The selected Git object is not a commit.")
        }

        let missingFile = "'--git-file' must identify a regular file in the selected commit."
        let tree = try git(["ls-tree", "-z", "--full-tree", commitID, "--", file], failure: missingFile)
        let entry = String(data: tree, encoding: .utf8)?.split(separator: "\t", maxSplits: 1) ?? []
        let fields = entry.first?.split(separator: " ") ?? []
        guard entry.count == 2,
              entry[1].last == "\0", entry[1].dropLast() == file,
              fields.count == 3, fields[0] == "100644" || fields[0] == "100755",
              fields[1] == "blob", Self.isObjectID(String(fields[2])) else {
            throw ValidationError(missingFile)
        }
        let committedPath = String(entry[1].dropLast())
        if let lineRange {
            let lineFailure = "Could not verify '--git-lines' in the selected commit. Use a UTF-8 text file up to 8 MiB."
            let blob = try git(["cat-file", "blob", String(fields[2])], limit: 8 * 1024 * 1024, failure: lineFailure)
            guard !blob.contains(0), String(data: blob, encoding: .utf8) != nil else {
                throw ValidationError(lineFailure)
            }
            let lineCount = blob.reduce(0) { $0 + ($1 == 10 ? 1 : 0) } + (blob.isEmpty || blob.last == 10 ? 0 : 1)
            guard lineRange.upperBound <= lineCount else {
                throw ValidationError("'--git-lines' exceeds the line count in the selected commit.")
            }
        }

        let remoteFailure = "Set a single GitHub or GitLab 'origin' remote with a credential-free HTTPS or Git SSH URL."
        let remote = try git(["config", "--null", "--local", "--get-all", "remote.origin.url"], failure: remoteFailure)
        let remoteValues = String(decoding: remote, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: false)
        guard remoteValues.count == 2, remoteValues[1].isEmpty,
              let (forge, project) = Self.parseRemote(String(remoteValues[0])) else {
            throw ValidationError(remoteFailure)
        }

        var target = URLComponents()
        target.scheme = "https"
        target.host = forge.rawValue
        target.path = "/\(project)/\(forge.blobPath)/\(commitID)/\(committedPath)"
        if let lineRange {
            if forge == .github, ["md", "markdown"].contains((committedPath as NSString).pathExtension.lowercased()) {
                target.queryItems = [URLQueryItem(name: "plain", value: "1")]
            }
            target.fragment = forge.lineFragment(lineRange)
        }
        guard let url = target.url else { throw ValidationError("Could not format the Git source link.") }
        return ("\(project)/\(committedPath)", url)
    }

    private static func isObjectID(_ value: String) -> Bool {
        let bytes = value.utf8
        return (bytes.count == 40 || bytes.count == 64)
            && bytes.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }

    private static func parseRemote(_ raw: String) -> (Forge, String)? {
        let address: String
        if !raw.contains("://"), let colon = raw.firstIndex(of: ":"), raw.hasPrefix("git@") {
            address = "ssh://\(raw[..<colon])/\(raw[raw.index(after: colon)...])"
        } else {
            address = raw
        }
        guard let components = URLComponents(string: address),
              let host = components.host?.lowercased(), let forge = Forge(rawValue: host),
              components.password == nil, components.query == nil, components.fragment == nil,
              components.percentEncodedPath == components.path, components.path.hasPrefix("/") else { return nil }
        switch components.scheme?.lowercased() {
        case "https" where components.user == nil && (components.port == nil || components.port == 443): break
        case "ssh" where components.user == "git" && (components.port == nil || components.port == 22): break
        default: return nil
        }
        var project = String(components.path.dropFirst())
        if project.hasSuffix("/") { project.removeLast() }
        if project.hasSuffix(".git") { project.removeLast(4) }
        let names = project.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        guard (forge == .github ? names.count == 2 : names.count >= 2),
              names.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy(allowed.contains) }) else {
            return nil
        }
        return (forge, project)
    }

    private func git(_ args: [String], limit: Int = 8192, failure: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--no-replace-objects", "--literal-pathspecs"] + (root.map { ["-C", $0] } ?? []) + args
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_NO_LAZY_FETCH": "1",
            "GIT_ALLOW_PROTOCOL": ""
        ]
        let output = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardOutput = output
        do {
            try process.run()
        } catch {
            throw ValidationError("Could not start the system Git executable.")
        }
        let data = output.fileHandleForReading.readData(ofLength: limit + 1)
        if data.count > limit, process.isRunning { process.terminate() }
        process.waitUntilExit()
        guard process.terminationStatus == 0, data.count <= limit else { throw ValidationError(failure) }
        return data
    }
}
