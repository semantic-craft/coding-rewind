// SPDX-License-Identifier: MIT

import Foundation
import NaturalLanguage

public struct IndexedClipTokens: Equatable, Sendable {
    public let excerptTokens: String
    public let promptTokens: String
    public let annotationTokens: String
    public let sourceTokens: String
    public let primaryTokenSet: Set<String>
    public let allTokenSet: Set<String>
}

public struct QueryTokenAnalysis: Equatable, Sendable {
    public let primaryTokens: [String]
    public let fallbackCJKUnigrams: [String]

    public var allSearchTokens: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for token in primaryTokens + fallbackCJKUnigrams where seen.insert(token).inserted {
            result.append(token)
        }
        return result
    }

    public var isEmpty: Bool {
        primaryTokens.isEmpty && fallbackCJKUnigrams.isEmpty
    }
}

public enum NaturalLanguageSearchTokenizer {
    private static let englishStopWords: Set<String> = [
        "a", "about", "above", "after", "again", "all", "am", "an", "and", "any", "are", "as", "at",
        "be", "because", "been", "before", "being", "below", "between", "both", "but", "by", "can",
        "could", "did", "do", "does", "doing", "down", "during", "each", "few", "for", "from", "further",
        "had", "has", "have", "having", "he", "her", "here", "hers", "herself", "him", "himself", "his",
        "how", "i", "if", "in", "into", "is", "it", "its", "itself", "just", "me", "more", "most", "my",
        "myself", "no", "nor", "not", "now", "of", "off", "on", "once", "only", "or", "other", "our",
        "ours", "ourselves", "out", "over", "own", "please", "same", "she", "should", "so", "some", "such",
        "than", "that", "the", "their", "theirs", "them", "themselves", "then", "there", "these", "they",
        "this", "those", "through", "to", "too", "under", "until", "up", "very", "was", "we", "were",
        "what", "when", "where", "which", "while", "who", "whom", "why", "will", "with", "would", "you",
        "your", "yours", "yourself", "yourselves", "tell", "find", "show", "remember", "idea", "thought"
    ]

    private static let cjkStopWords: Set<String> = [
        "的", "了", "在", "是", "我", "有", "和", "就", "不", "人", "都", "一", "一个", "上", "也", "很",
        "到", "说", "要", "去", "你", "会", "着", "没有", "看", "好", "自己", "这", "那", "个", "里",
        "么", "什", "什么", "怎么", "如何", "为什么", "为啥", "那个", "这个", "哪些", "哪个", "前两天",
        "之前", "刚才", "关于", "请问", "能不能", "可以", "帮我", "找一下", "看看", "记得", "时候",
        "用", "把", "被", "让", "给", "对", "跟", "从", "向", "往", "于", "与", "及", "或", "而",
        "且", "但", "却", "又", "还", "再", "更", "最", "太", "真", "挺", "吧", "呢", "吗", "啊", "呀"
    ]

    public static func indexTokens(for clip: Clip) -> IndexedClipTokens {
        let excerptAnalyzed = analyzeText(clip.excerpt, filterStopWords: false)
        let promptAnalyzed = analyzeText(clip.promptContext.capturedText ?? "", filterStopWords: false)
        let annotationRaw = [
            clip.annotation.title ?? "",
            clip.annotation.tags.joined(separator: " "),
            clip.annotation.userNote ?? ""
        ].joined(separator: " ")
        let annotationAnalyzed = analyzeText(annotationRaw, filterStopWords: false)

        let sourceRaw: String
        switch clip.source {
        case .antigravity(let conversationId, let workspacePath, let locator):
            sourceRaw = ["antigravity", conversationId ?? "", workspacePath ?? "", locator ?? ""].joined(separator: " ")
        case .web(let site, let url, let pageTitle):
            sourceRaw = [site.rawValue, site.displayName, url ?? "", pageTitle ?? ""].joined(separator: " ")
        case .desktop(let bundleIdentifier, let appName, let windowTitle):
            sourceRaw = [bundleIdentifier, appName, windowTitle ?? ""].joined(separator: " ")
        }
        let sourceAnalyzed = analyzeText(sourceRaw, filterStopWords: false)

        var primarySet = Set<String>()
        for token in excerptAnalyzed.primaryTokens + promptAnalyzed.primaryTokens + annotationAnalyzed.primaryTokens + sourceAnalyzed.primaryTokens {
            primarySet.insert(token)
        }
        var allSet = primarySet
        for token in excerptAnalyzed.fallbackCJKUnigrams + promptAnalyzed.fallbackCJKUnigrams + annotationAnalyzed.fallbackCJKUnigrams + sourceAnalyzed.fallbackCJKUnigrams {
            allSet.insert(token)
        }

        return IndexedClipTokens(
            excerptTokens: excerptAnalyzed.allSearchTokens.joined(separator: " "),
            promptTokens: promptAnalyzed.allSearchTokens.joined(separator: " "),
            annotationTokens: annotationAnalyzed.allSearchTokens.joined(separator: " "),
            sourceTokens: sourceAnalyzed.allSearchTokens.joined(separator: " "),
            primaryTokenSet: primarySet,
            allTokenSet: allSet
        )
    }

    public static func analyzeQuery(_ rawQuery: String) -> QueryTokenAnalysis {
        analyzeText(rawQuery, filterStopWords: true)
    }

    private static func analyzeText(_ text: String, filterStopWords: Bool) -> QueryTokenAnalysis {
        let normalized = text.lowercased()
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return QueryTokenAnalysis(primaryTokens: [], fallbackCJKUnigrams: [])
        }

        var primaryTokens: [String] = []
        var primarySeen = Set<String>()
        var cjkUnigrams: [String] = []
        var unigramSeen = Set<String>()

        func appendPrimary(_ candidate: String) {
            let clean = sanitizeToken(candidate)
            guard !clean.isEmpty else { return }
            if filterStopWords && (englishStopWords.contains(clean) || cjkStopWords.contains(clean)) {
                return
            }
            if containsCJKScalar(clean) {
                guard clean.count >= 2 else { return }
            } else {
                guard clean.count >= 2 else { return }
            }
            if primarySeen.insert(clean).inserted {
                primaryTokens.append(clean)
            }
        }

        func appendUnigram(_ candidate: String) {
            let clean = sanitizeToken(candidate)
            guard clean.count == 1, containsCJKScalar(clean) else { return }
            if cjkStopWords.contains(clean) { return }
            if unigramSeen.insert(clean).inserted {
                cjkUnigrams.append(clean)
            }
        }

        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = normalized
        tokenizer.enumerateTokens(in: normalized.startIndex..<normalized.endIndex) { range, _ in
            let word = String(normalized[range])
            if containsCJKScalar(word) {
                if word.count >= 2 {
                    appendPrimary(word)
                } else if word.count == 1 {
                    appendUnigram(word)
                }
            } else {
                appendPrimary(word)
                for stem in englishLemmaAndStemVariants(for: word) {
                    appendPrimary(stem)
                }
            }
            return true
        }

        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = normalized
        tagger.enumerateTags(
            in: normalized.startIndex..<normalized.endIndex,
            unit: .word,
            scheme: .lemma,
            options: [.omitPunctuation, .omitWhitespace]
        ) { tag, _ in
            if let lemma = tag?.rawValue.lowercased(), !lemma.isEmpty {
                appendPrimary(lemma)
            }
            return true
        }

        for run in contiguousCJKRuns(in: normalized) {
            var filteredScalars: [Character] = []
            for ch in run {
                let single = String(ch)
                if !cjkStopWords.contains(single) {
                    filteredScalars.append(ch)
                    appendUnigram(single)
                }
            }
            if filteredScalars.count >= 2 {
                for idx in 0..<(filteredScalars.count - 1) {
                    let bigram = String([filteredScalars[idx], filteredScalars[idx + 1]])
                    appendPrimary(bigram)
                }
            }
        }

        return QueryTokenAnalysis(
            primaryTokens: primaryTokens,
            fallbackCJKUnigrams: cjkUnigrams
        )
    }

    private static func sanitizeToken(_ raw: String) -> String {
        var result = ""
        for scalar in raw.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || isCJKScalar(scalar) {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    private static func containsCJKScalar(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isCJKScalar)
    }

    private static func isCJKScalar(_ scalar: UnicodeScalar) -> Bool {
        (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
    }

    private static func contiguousCJKRuns(in text: String) -> [[Character]] {
        var runs: [[Character]] = []
        var current: [Character] = []
        for ch in text {
            if ch.unicodeScalars.allSatisfy(isCJKScalar) {
                current.append(ch)
            } else if !current.isEmpty {
                runs.append(current)
                current = []
            }
        }
        if !current.isEmpty {
            runs.append(current)
        }
        return runs
    }

    private static func englishLemmaAndStemVariants(for word: String) -> [String] {
        let clean = sanitizeToken(word)
        guard clean.count >= 4, !containsCJKScalar(clean) else { return [] }
        var variants: [String] = []
        if clean.hasSuffix("ies") && clean.count > 4 {
            variants.append(String(clean.dropLast(3)) + "y")
        }
        if clean.hasSuffix("ing") && clean.count > 5 {
            let base = String(clean.dropLast(3))
            variants.append(base)
            variants.append(base + "e")
        }
        if clean.hasSuffix("ed") && clean.count > 4 {
            let base = String(clean.dropLast(2))
            variants.append(base)
            variants.append(base + "e")
        }
        if clean.hasSuffix("es") && clean.count > 4 {
            variants.append(String(clean.dropLast(2)))
        } else if clean.hasSuffix("s") && !clean.hasSuffix("ss") && clean.count > 3 {
            variants.append(String(clean.dropLast(1)))
        }
        return variants
    }
}
