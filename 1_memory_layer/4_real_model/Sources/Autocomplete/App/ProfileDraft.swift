import Foundation

/// Builds the pre-filled "About you" draft for onboarding step 3. Pure string
/// logic — no UI, no permissions. Seeds a first-person intro (name + writing
/// languages) plus two optional, skippable section headings, which are kept
/// verbatim (empty or not) when the user saves.
enum ProfileDraft {
    /// Pre-filled editor contents shown when the profile page first appears.
    static func seeded() -> String {
        let intro = introLine()
        return """
        \(intro)

        Contact info:


        More about me:
        """
    }

    // MARK: - Private

    private static func introLine() -> String {
        let name = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        let langs = writingLanguages()
        switch (name.isEmpty, langs.isEmpty) {
        case (false, false): return "I'm \(name). I write in \(langs)."
        case (false, true):  return "I'm \(name)."
        case (true, false):  return "I write in \(langs)."
        case (true, true):   return ""
        }
    }

    /// Top 1–2 distinct languages from the system's preferred languages, rendered
    /// as English display names ("English and Chinese") to match the English intro.
    private static func writingLanguages() -> String {
        let english = Locale(identifier: "en")
        var seen = Set<String>()
        var names: [String] = []
        for id in Locale.preferredLanguages {
            guard let code = Locale(identifier: id).language.languageCode?.identifier,
                  !seen.contains(code) else { continue }
            seen.insert(code)
            if let name = english.localizedString(forLanguageCode: code) {
                names.append(name)
            }
            if names.count == 2 { break }
        }
        switch names.count {
        case 0:  return ""
        case 1:  return names[0]
        default: return "\(names[0]) and \(names[1])"
        }
    }
}
