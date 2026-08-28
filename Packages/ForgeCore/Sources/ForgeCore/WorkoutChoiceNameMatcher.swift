import Foundation

public enum WorkoutChoiceNameMatchQuality: Int, Codable, Sendable {
    case exact
    case conversationalExact
    case partial
    case category
}

public struct WorkoutChoiceNameMatch: Equatable, Sendable {
    public let record: WorkoutChoiceRecord
    public let quality: WorkoutChoiceNameMatchQuality

    public init(
        record: WorkoutChoiceRecord,
        quality: WorkoutChoiceNameMatchQuality
    ) {
        self.record = record
        self.quality = quality
    }
}

/// Resolves natural spoken forms to the stable workout identifiers exposed by
/// ForgeFit's App Entities. The matcher is intentionally deterministic: Siri
/// owns speech recognition, while ForgeFit handles the text variants that are
/// predictable from a saved title (spacing, punctuation, acronyms, and
/// numbers). It never guesses by exercise content or silently substitutes a
/// different saved routine.
public enum WorkoutChoiceNameMatcher {
    private static let leadingRequestWords: Set<String> = [
        "begin", "do", "launch", "open", "please", "run", "start",
    ]
    private static let leadingDeterminers: Set<String> = [
        "a", "an", "my", "the",
    ]
    private static let leadingRequestPhrases: [[String]] = [
        ["can", "you"], ["could", "you"], ["would", "you"],
        ["i", "want", "to"], ["i", "d", "like", "to"],
    ]
    private static let nameIntroducers: Set<String> = ["called", "named"]
    private static let trailingTypeWords: Set<String> = [
        "plan", "routine", "session", "training", "workout",
    ]

    /// Returns only the best-quality matches. Equal-quality duplicates remain
    /// in the result so App Intents can ask the person to disambiguate instead
    /// of ForgeFit choosing one arbitrarily.
    public static func matches(
        query: String,
        in records: [WorkoutChoiceRecord],
        appName: String = "ForgeFit"
    ) -> [WorkoutChoiceNameMatch] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return records.map {
                WorkoutChoiceNameMatch(record: $0, quality: .category)
            }
        }

        let candidates = queryCandidates(query, appName: appName)
        var exactMatches: [(match: WorkoutChoiceNameMatch, rank: Int)] = []

        for record in records {
            let keys = searchKeys(for: record)
            for (rank, candidate) in candidates.enumerated()
                where keys.contains(candidate) {
                exactMatches.append((
                    WorkoutChoiceNameMatch(
                        record: record,
                        quality: rank == 0 ? .exact : .conversationalExact
                    ),
                    rank
                ))
                break
            }
        }

        if let bestRank = exactMatches.map(\.rank).min() {
            return exactMatches
                .filter { $0.rank == bestRank }
                .map(\.match)
                .sorted(by: matchSort)
        }

        guard let partialCandidate = candidates.last(where: { $0.count >= 3 }) else {
            return []
        }
        let partialMatches = records.compactMap { record -> WorkoutChoiceNameMatch? in
            let keys = searchKeys(for: record)
            guard keys.contains(where: {
                $0.hasPrefix(partialCandidate) || $0.contains(partialCandidate)
            }) else { return nil }
            return WorkoutChoiceNameMatch(record: record, quality: .partial)
        }
        if !partialMatches.isEmpty {
            return partialMatches.sorted(by: matchSort)
        }

        return records.compactMap { record -> WorkoutChoiceNameMatch? in
            let subtitleKey = comparisonKey(record.subtitle)
            guard subtitleKey.contains(partialCandidate) else { return nil }
            return WorkoutChoiceNameMatch(record: record, quality: .category)
        }
        .sorted(by: matchSort)
    }

    /// Human-readable aliases suitable for Spotlight keywords and diagnostics.
    /// These are derived from the title, never from private workout history.
    public static func spokenAliases(for title: String) -> [String] {
        let segments = spokenSegments(in: title)
        guard !segments.isEmpty else { return [] }

        var aliases: [String] = []
        for letterRendering in [
            LetterRendering.literal,
            .letterNames,
            .pronunciation,
        ] {
            for numberRendering in [
                NumberRendering.digits,
                .cardinal,
                .individualDigits,
                .individualDigitsUsingOh,
            ] {
                appendUnique(
                    render(
                        segments,
                        letters: letterRendering,
                        numbers: numberRendering
                    ),
                    to: &aliases
                )
            }
        }
        if segments.contains(where: { segment in
            if case .digits = segment { true } else { false }
        }) {
            for alias in Array(aliases) {
                for (word, homophones) in numberHomophones {
                    for homophone in homophones {
                        appendUnique(
                            replacingWholeWord(word, with: homophone, in: alias),
                            to: &aliases
                        )
                    }
                }
            }
        }

        return aliases.filter { !$0.isEmpty }
    }

    private static func queryCandidates(
        _ query: String,
        appName: String
    ) -> [String] {
        var phrases = [query]
        var queryWords = words(in: query)
        while queryWords.last == "please" {
            queryWords.removeLast()
        }
        let appWords = words(in: appName)
        let withoutApp = removingAppQualifier(from: queryWords, appWords: appWords)
        appendUnique(withoutApp.joined(separator: " "), to: &phrases)

        var unwrapped = withoutApp
        if let prefix = leadingRequestPhrases
            .sorted(by: { $0.count > $1.count })
            .first(where: { unwrapped.starts(with: $0) }) {
            unwrapped.removeFirst(prefix.count)
        }
        while let first = unwrapped.first, leadingRequestWords.contains(first) {
            unwrapped.removeFirst()
        }
        while let first = unwrapped.first, leadingDeterminers.contains(first) {
            unwrapped.removeFirst()
        }
        if let first = unwrapped.first, trailingTypeWords.contains(first) {
            unwrapped.removeFirst()
        }
        if let first = unwrapped.first, nameIntroducers.contains(first) {
            unwrapped.removeFirst()
        }
        while unwrapped.last == "please" {
            unwrapped.removeLast()
        }
        while let last = unwrapped.last, trailingTypeWords.contains(last) {
            unwrapped.removeLast()
        }
        appendUnique(unwrapped.joined(separator: " "), to: &phrases)

        var keys: [String] = []
        for phrase in phrases {
            for alias in spokenAliases(for: phrase) {
                appendUnique(comparisonKey(alias), to: &keys)
            }
        }
        return keys.filter { !$0.isEmpty }
    }

    private static func removingAppQualifier(
        from words: [String],
        appWords: [String]
    ) -> [String] {
        let compactAppName = appWords.joined()
        var appPatterns = [
            appWords,
            [compactAppName],
            appWords + ["app"],
            [compactAppName, "app"],
            ["the"] + appWords,
            ["the", compactAppName],
            ["the"] + appWords + ["app"],
            ["the", compactAppName, "app"],
        ]
        if compactAppName == "forgefit" {
            appPatterns += [
                ["forge", "fit"], ["forged", "fit"], ["forgeift"],
                ["forge", "fit", "app"], ["forged", "fit", "app"],
                ["the", "forge", "fit", "app"],
            ]
        }
        appPatterns = appPatterns
        .filter { !$0.isEmpty }
        .sorted { $0.count > $1.count }
        let prepositions: Set<String> = ["in", "on", "using", "with"]

        for pattern in appPatterns {
            guard words.count > pattern.count,
                  words.suffix(pattern.count).elementsEqual(pattern) else {
                continue
            }
            var result = Array(words.dropLast(pattern.count))
            if let last = result.last, prepositions.contains(last) {
                result.removeLast()
            }
            return result
        }
        return words
    }

    private static func searchKeys(for record: WorkoutChoiceRecord) -> Set<String> {
        var phrases = spokenAliases(for: record.title)
        switch WorkoutChoiceTarget(identifier: record.id) {
        case .next:
            phrases += [
                "next", "next routine", "next workout", "planned workout",
                "scheduled workout", "today's workout", "upcoming workout",
            ]
        case .empty:
            phrases += ["blank", "blank workout", "empty", "empty workout"]
        default:
            break
        }
        return Set(phrases.map(comparisonKey).filter { !$0.isEmpty })
    }

    private static func comparisonKey(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US")
            )
            .replacing("&", with: " and ")
            .unicodeScalars
            .filter(CharacterSet.alphanumerics.contains)
            .map(String.init)
            .joined()
    }

    private static func words(in value: String) -> [String] {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US")
            )
            .replacing("&", with: " and ")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func matchSort(
        _ lhs: WorkoutChoiceNameMatch,
        _ rhs: WorkoutChoiceNameMatch
    ) -> Bool {
        let comparison = lhs.record.title.localizedStandardCompare(rhs.record.title)
        return comparison == .orderedSame
            ? lhs.record.id < rhs.record.id
            : comparison == .orderedAscending
    }

    private static func appendUnique(_ value: String, to values: inout [String]) {
        guard !value.isEmpty, !values.contains(value) else { return }
        values.append(value)
    }

    private static func replacingWholeWord(
        _ word: String,
        with replacement: String,
        in phrase: String
    ) -> String {
        phrase
            .split(separator: " ")
            .map { $0 == Substring(word) ? replacement : String($0) }
            .joined(separator: " ")
    }
}

private extension WorkoutChoiceNameMatcher {
    enum SpokenSegment {
        case letters(original: String, folded: String)
        case digits(String)
    }

    enum LetterRendering {
        case literal
        case letterNames
        case pronunciation
    }

    enum NumberRendering {
        case digits
        case cardinal
        case individualDigits
        case individualDigitsUsingOh
    }

    static func spokenSegments(in value: String) -> [SpokenSegment] {
        let expanded = value.replacing("&", with: " and ")
        var segments: [SpokenSegment] = []
        var buffer = ""
        var bufferIsDigit: Bool?

        func flush() {
            guard !buffer.isEmpty, let bufferIsDigit else { return }
            if bufferIsDigit {
                segments.append(.digits(buffer))
            } else {
                let folded = buffer.folding(
                    options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                    locale: Locale(identifier: "en_US")
                )
                segments.append(.letters(original: buffer, folded: folded.lowercased()))
            }
            buffer = ""
        }

        for character in expanded {
            let isDigit = character.isNumber
            guard character.isLetter || isDigit else {
                flush()
                bufferIsDigit = nil
                continue
            }
            if let bufferIsDigit, bufferIsDigit != isDigit {
                flush()
            }
            bufferIsDigit = isDigit
            buffer.append(character)
        }
        flush()
        return segments
    }

    static func render(
        _ segments: [SpokenSegment],
        letters: LetterRendering,
        numbers: NumberRendering
    ) -> String {
        segments.flatMap { segment -> [String] in
            switch segment {
            case .letters(let original, let folded):
                switch letters {
                case .literal:
                    return [folded]
                case .letterNames:
                    guard isSpokenAcronym(original, folded: folded) else {
                        return [folded]
                    }
                    return original.lowercased().compactMap { letterNames[$0] }
                case .pronunciation:
                    guard isSpokenAcronym(original, folded: folded),
                          let pronunciation = acronymPronunciations[folded] else {
                        return [folded]
                    }
                    return [pronunciation]
                }
            case .digits(let value):
                switch numbers {
                case .digits:
                    return [value]
                case .cardinal:
                    return cardinalWords(for: value)
                case .individualDigits:
                    return digitWords(for: value, zeroWord: "zero")
                case .individualDigitsUsingOh:
                    return digitWords(for: value, zeroWord: "oh")
                }
            }
        }
        .joined(separator: " ")
    }

    static func isAcronym(_ value: String) -> Bool {
        let letters = value.filter(\.isLetter)
        return !letters.isEmpty
            && letters.count <= 8
            && value == value.uppercased()
    }

    static func isSpokenAcronym(_ original: String, folded: String) -> Bool {
        isAcronym(original) || acronymPronunciations[folded] != nil
    }

    static func cardinalWords(for digits: String) -> [String] {
        guard !digits.isEmpty,
              !digits.hasPrefix("0"),
              digits.count <= 9,
              let value = Int(digits),
              let cardinal = englishCardinal(value) else {
            return digitWords(for: digits, zeroWord: "zero")
        }
        return cardinal.split(separator: " ").map(String.init)
    }

    static func digitWords(for digits: String, zeroWord: String) -> [String] {
        digits.compactMap { character in
            guard let value = character.wholeNumberValue else { return nil }
            return value == 0 ? zeroWord : smallNumbers[value]
        }
    }

    static func englishCardinal(_ value: Int) -> String? {
        guard value >= 0, value < 1_000_000_000 else { return nil }
        if value < 20 { return smallNumbers[value] }
        if value < 100 {
            let tens = tensWords[value / 10]
            let remainder = value % 10
            return remainder == 0 ? tens : "\(tens) \(smallNumbers[remainder])"
        }
        if value < 1_000 {
            let remainder = value % 100
            let hundreds = "\(smallNumbers[value / 100]) hundred"
            guard remainder > 0, let words = englishCardinal(remainder) else { return hundreds }
            return "\(hundreds) \(words)"
        }
        if value < 1_000_000 {
            return groupedCardinal(value, unit: 1_000, unitName: "thousand")
        }
        return groupedCardinal(value, unit: 1_000_000, unitName: "million")
    }

    static func groupedCardinal(_ value: Int, unit: Int, unitName: String) -> String? {
        guard let leading = englishCardinal(value / unit) else { return nil }
        let remainder = value % unit
        guard remainder > 0, let trailing = englishCardinal(remainder) else {
            return "\(leading) \(unitName)"
        }
        return "\(leading) \(unitName) \(trailing)"
    }

    static let smallNumbers = [
        "zero", "one", "two", "three", "four", "five", "six", "seven",
        "eight", "nine", "ten", "eleven", "twelve", "thirteen", "fourteen",
        "fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
    ]

    static let tensWords = [
        "", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy",
        "eighty", "ninety",
    ]

    static let letterNames: [Character: String] = [
        "a": "ay", "b": "bee", "c": "see", "d": "dee", "e": "ee",
        "f": "ef", "g": "gee", "h": "aitch", "i": "eye", "j": "jay",
        "k": "kay", "l": "el", "m": "em", "n": "en", "o": "oh",
        "p": "pee", "q": "cue", "r": "ar", "s": "ess", "t": "tee",
        "u": "you", "v": "vee", "w": "double u", "x": "ex", "y": "why",
        "z": "zee",
    ]

    /// Common speech recognizer renderings for compact fitness/programming
    /// acronyms. These apply to tokens, not to any specific routine record.
    static let acronymPronunciations: [String: String] = [
        "ax": "axe",
        "hiit": "hit",
    ]

    static let numberHomophones: [String: [String]] = [
        "one": ["won"],
        "two": ["to", "too"],
        "four": ["for"],
        "eight": ["ate"],
        "zero": ["oh"],
    ]
}
