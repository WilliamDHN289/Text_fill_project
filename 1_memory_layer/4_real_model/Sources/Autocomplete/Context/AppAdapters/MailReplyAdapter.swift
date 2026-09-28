import Foundation

/// Three-part split of a mail reply's suffix. Lossless: lead + newest + (older ?? "")
/// reassembles the input exactly.
struct MailQuote: Equatable {
    /// Text between the caret and the first attribution line — the user's OWN
    /// content below the cursor (rest of draft, signature). May be empty or
    /// whitespace-only; rendered under the plain suffix label, never as quote.
    let lead: String
    /// First attribution line through just before the second (the message being
    /// replied to). Structurally non-empty (starts with the attribution line).
    let newest: String
    /// Second attribution onward (older history); nil if only one message in window.
    let older: String?
}

/// How a provider should present the suffix.
/// - `.plain`: today's generic suffix labels (cloud's encrypted one / "Below the cursor:").
/// - `.mailReply(quote:)`: recognized mail reply WITH a parsed attribution boundary.
///   There is deliberately no "recognized but unparsed" state: a non-empty suffix
///   without an attribution is indistinguishable from the user's own draft text
///   below the caret, so Engine maps that case to `.plain` (mislabeling the user's
///   own words as quoted history would be worse than no label).
enum SuffixKind: Equatable {
    case plain
    case mailReply(quote: MailQuote)
}

/// Per-app preprocessor for email replies. Sibling to `ClaudeCodeAdapter`.
/// The GATE (`matches`) is app-identity — language-independent and robust.
/// Attribution detection is a best-effort REFINEMENT: a miss degrades to label-only,
/// never to broken. Pure `Foundation` so it is exercised by `runSelfChecks()`.
enum MailReplyAdapter {

    // MARK: - Gate (app identity)

    /// Web mail is gated by the window-title brand. CONFIRMED (2026-06-10 live QA):
    /// a real Gmail compose title segments as ["<subject>", "<account email>",
    /// "gmail", "high memory usage", "982 mb", "google chrome", "<profile>"] — the
    /// brand segment is present mid-title (NOT title-end: Chrome appends memory
    /// chip, browser name, and profile), which is exactly why this is segment
    /// EQUALITY rather than hasSuffix. If a client ever drops the brand segment,
    /// the hardening path is the focused web area's AXURL
    /// (`mail.google.com` / `outlook.*`) instead of the title.
    static func matches(appBundleId: String, windowTitle: String, appName: String) -> Bool {
        // Desktop mail: language-independent bundle ids.
        if desktopMailBundleIds.contains(appBundleId) { return true }
        // Web mail: a browser whose window title carries a mail brand as a
        // standalone " - "-delimited segment (web mail titles end in
        // "… - Gmail [- Google Chrome]"). Segment EQUALITY, not substring —
        // a Doc titled "Economic outlook 2026 - Google Docs" must not match.
        if browserBundleIds.contains(appBundleId) {
            let segments = windowTitle.lowercased()
                .components(separatedBy: " - ")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let hit = segments.contains(where: { webMailBrands.contains($0) })
            Log.debug("[MailGate] browser title segments=\(segments) → \(hit ? "mail" : "not mail")")
            if hit { return true }
        }
        return false
    }

    // MARK: - Tunables

    /// "New Outlook" on macOS currently ships under the same bundle id; confirm during live QA.
    private static let desktopMailBundleIds: Set<String> = [
        "com.apple.mail",
        "com.microsoft.Outlook",
    ]
    private static let browserBundleIds: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary",
        "com.apple.Safari", "com.microsoft.edgemac",
        "com.brave.Browser", "company.thebrowser.Browser", // Arc
    ]
    private static let webMailBrands: [String] = ["gmail", "outlook"]

    // MARK: - Attribution detection (structural, per-family)

    /// True when the suffix's first attribution line is preceded by whitespace only —
    /// i.e. the caret sits directly against the quoted thread (Gmail's AX flattening
    /// puts the attribution on the caret's own line). Used by the `shouldSuggest`
    /// override; deliberately NOT anywhere-in-suffix: draft text between the caret
    /// and the quote means a mid-draft edit, which must follow the normal
    /// end-of-line gating like every other app.
    static func detectsQuoteAtSuffixHead(_ suffix: String) -> Bool {
        guard let first = attributionLineRanges(in: suffix).first else { return false }
        return suffix[..<first].allSatisfy(\.isWhitespace)
    }

    /// Start indices (in `text`) of each detected attribution line, top to bottom.
    /// Precision comes from STRUCTURE (bracketed email, line-start anchor, consecutive
    /// header cluster, literal divider), not from word lists — so body prose like
    /// "On Monday she wrote a letter" or a lone "From: the team" does not match.
    static func attributionLineRanges(in text: String) -> [String.Index] {
        let lines = splitKeepingIndices(text)
        var starts: [String.Index] = []
        var i = 0
        while i < lines.count {
            let (start, content) = lines[i]
            if isOnFamilyAttribution(content) || isDivider(content) {
                starts.append(start)
                i += 1
                continue
            }
            // Outlook header block: >=2 consecutive header lines, a From: with <email>.
            if isHeaderLine(content) != nil {
                var j = i
                var sawFromWithEmail = false
                while j < lines.count, let key = isHeaderLine(lines[j].1) {
                    if key == "From:" && containsBracketedEmail(lines[j].1) { sawFromWithEmail = true }
                    j += 1
                }
                if j - i >= 2 && sawFromWithEmail {
                    starts.append(start)
                    i = j
                    continue
                }
            }
            i += 1
        }
        return starts
    }

    // MARK: - Segmentation (keep-and-annotate; never deletes)

    /// Split the (already 2000-capped) suffix at its attribution lines.
    /// - 0 attributions → nil (Engine maps this to `.plain`).
    /// - text before the FIRST attribution (user's own draft/signature) → `lead`,
    ///   rendered under the plain label so the user's words are never presented
    ///   as the counterpart's message.
    /// - 1 attribution  → `newest` = first attribution…end, `older` = nil.
    /// - ≥2 attributions → `newest` = first…second attribution, `older` = second…end.
    static func preprocess(rawSuffix: String) -> MailQuote? {
        let starts = attributionLineRanges(in: rawSuffix)
        guard let first = starts.first else { return nil }
        let lead = String(rawSuffix[rawSuffix.startIndex..<first])
        if starts.count == 1 {
            return MailQuote(lead: lead, newest: String(rawSuffix[first...]), older: nil)
        }
        let second = starts[1]
        return MailQuote(
            lead: lead,
            newest: String(rawSuffix[first..<second]),
            older: String(rawSuffix[second...])
        )
    }

    // MARK: - Per-family line tests

    private static func isOnFamilyAttribution(_ line: String) -> Bool {
        let s = stripQuoteMarkers(line)
        guard containsBracketedEmail(s) else { return false }
        let lower = s.lowercased()
        let startsOK = onFamilyLeads.contains { lower.hasPrefix($0) }
        let endsOK = onFamilyTerminals.contains { lower.hasSuffix($0) }
        return startsOK && endsOK
    }

    private static func isHeaderLine(_ line: String) -> String? {
        let s = stripQuoteMarkers(line)
        for key in headerKeys where s.hasPrefix(key) { return key }
        return nil
    }

    private static func isDivider(_ line: String) -> Bool {
        let s = stripQuoteMarkers(line).trimmingCharacters(in: .whitespaces)
        return s.range(of: #"^-{3,}\s*Original Message\s*-{3,}$"#, options: .regularExpression) != nil
    }

    // MARK: - Structural helpers

    /// True if the line contains an email inside angle brackets: `<…@…>`.
    /// Note: only the FIRST `<…>` pair is inspected — fine for rendered AX text,
    /// where no HTML tags survive; revisit only if a real-world miss appears.
    private static func containsBracketedEmail(_ s: String) -> Bool {
        guard let lt = s.firstIndex(of: "<") else { return false }
        let rest = s[s.index(after: lt)...]
        guard let gt = rest.firstIndex(of: ">") else { return false }
        return rest[..<gt].contains("@")
    }

    /// Drop leading quote markers (`>`) and whitespace so nested attributions match.
    private static func stripQuoteMarkers(_ line: String) -> String {
        var s = Substring(line)
        while let f = s.first, f == ">" || f == " " || f == "\t" { s = s.dropFirst() }
        return String(s)
    }

    /// Split into (lineStartIndex, lineContent) preserving indices into the original string.
    /// Splits on ANY Unicode line terminator via `Character.isNewline` — including
    /// vertical tabs (\u{0B}), which Outlook's Word engine uses as soft line breaks
    /// inside its From:/Date:/To:/Subject: header blocks (verified from live AX text),
    /// and the single-grapheme "\r\n" cluster. Start indices always point into the
    /// exact string passed in.
    private static func splitKeepingIndices(_ text: String) -> [(String.Index, String)] {
        var out: [(String.Index, String)] = []
        var lineStart = text.startIndex
        var idx = text.startIndex
        while idx < text.endIndex {
            if text[idx].isNewline {
                out.append((lineStart, String(text[lineStart..<idx])))
                lineStart = text.index(after: idx)
            }
            idx = text.index(after: idx)
        }
        out.append((lineStart, String(text[lineStart..<text.endIndex])))
        return out
    }

    // MARK: - Localized word tables (English v1; add confirmed CJK pairs later)

    /// Lead tokens that begin an `On … wrote:` attribution — pre-lowercased, and each
    /// carries its own boundary (latin leads end in a space; CJK leads like `在` don't).
    /// `at ` covers 163/NetEase webmail attributions
    /// (`At 2025-09-04 05:51:46, "Name" <addr> wrote:`), observed live 2026-06-11.
    /// Add `在` / `le ` / `am ` once confirmed against the user's real messages (open item).
    private static let onFamilyLeads: [String] = ["on ", "at "]
    /// Terminal words that end the attribution line. Add `写道:` / `写道：` later.
    private static let onFamilyTerminals: [String] = ["wrote:"]
    /// Outlook header-block keys. Add `发件人:` / `发送时间:` / `收件人:` / `主题:` later.
    private static let headerKeys: [String] = ["From:", "Sent:", "Date:", "To:", "Cc:", "Subject:"]
}

#if DEBUG
extension MailReplyAdapter {
    /// Runs a case table over the pure logic and logs PASS/FAIL to ~/.autocomplete.log.
    /// Called once from AppDelegate in DEBUG builds — this is the project's substitute
    /// for a unit-test target (the executable SPM package has none).
    static func runSelfChecks() {
        var pass = 0
        var fail = 0
        func check(_ name: String, _ condition: Bool) {
            if condition { pass += 1 }
            else { fail += 1; Log.info("[MailReplySelfCheck] FAIL: \(name)") }
        }

        // Gate — desktop
        check("gate: Apple Mail", matches(appBundleId: "com.apple.mail", windowTitle: "Re: hi", appName: "Mail"))
        check("gate: Outlook desktop", matches(appBundleId: "com.microsoft.Outlook", windowTitle: "Re: hi", appName: "Microsoft Outlook"))
        // Gate — web
        check("gate: Gmail web", matches(appBundleId: "com.google.Chrome", windowTitle: "Subject - me@x.com - Gmail", appName: "Google Chrome"))
        check("gate: Outlook web", matches(appBundleId: "com.google.Chrome", windowTitle: "Mail - Me - Outlook", appName: "Google Chrome"))
        // Gate — positives with browser suffix
        check("gate: Gmail web + browser suffix", matches(appBundleId: "com.google.Chrome", windowTitle: "Subject - me@x.com - Gmail - Google Chrome", appName: "Google Chrome"))
        // Gate — negatives
        check("gate: not Google Docs", !matches(appBundleId: "com.google.Chrome", windowTitle: "My Doc - Google Docs", appName: "Google Chrome"))
        check("gate: not 'Economic outlook' doc", !matches(appBundleId: "com.google.Chrome", windowTitle: "Economic outlook 2026 - Google Docs", appName: "Google Chrome"))
        check("gate: not TextEdit", !matches(appBundleId: "com.apple.TextEdit", windowTitle: "Untitled", appName: "TextEdit"))

        // Attribution — On family (Apple Mail / Gmail), real lines
        check("attr: On…wrote: matches", detectsQuoteAtSuffixHead(
            "On Jun 9, 2026, at 10:41 PM, CAMPAIGN HQ <campaign@e.example.org> wrote:\n> body"))
        check("attr: nested >On…wrote: matches", detectsQuoteAtSuffixHead(
            "> > On Jun 8, 2026, Bob <bob@x.com> wrote:\n> > body"))
        // Attribution — Outlook header block
        check("attr: Outlook header block matches", detectsQuoteAtSuffixHead(
            "From: Anupam <anupam@example.com>\nDate: Monday, June 8, 2026 at 2:26 PM\nTo: Xin <xin@x.edu>\nSubject: Re: hi"))
        // Attribution — divider
        check("attr: Original Message divider matches", detectsQuoteAtSuffixHead(
            "-----Original Message-----\nFrom: x"))
        // FALSE POSITIVES — body prose must NOT match
        check("attr: prose 'On Monday she wrote' no match", !detectsQuoteAtSuffixHead(
            "On Monday she wrote a letter to her friend."))
        check("attr: lone 'From: the team' no match", !detectsQuoteAtSuffixHead(
            "From: the marketing team we learned a lot."))
        check("attr: On…wrote: without email no match", !detectsQuoteAtSuffixHead(
            "On Jun 9 someone wrote:"))
        // CRLF line endings (AX text from web views can be CRLF)
        check("attr: CRLF On…wrote: matches", detectsQuoteAtSuffixHead(
            "On Jun 9, 2026, Bob <bob@x.com> wrote:\r\n> body"))
        // Outlook block rejection conjuncts, tested independently
        check("attr: single From:+email line no match", !detectsQuoteAtSuffixHead(
            "From: Bob <bob@x.com>\nthanks for the intro"))
        check("attr: headers without From-email no match", !detectsQuoteAtSuffixHead(
            "To: Bob\nSubject: Re: hi"))
        check("attr: Sent:-led block with From: second matches", detectsQuoteAtSuffixHead(
            "Sent: Monday, June 8, 2026\nFrom: Anupam <a@x.com>\nTo: Xin <x@x.edu>"))

        // Segmentation
        check("seg: 0 attributions → nil", preprocess(rawSuffix: "just my signature\nLeo") == nil)
        let oneAttr = "\nOn Jun 9, 2026, Bob <bob@x.com> wrote:\n> hello there"
        check("seg: 1 attribution → newest from attribution, lead captured",
              preprocess(rawSuffix: oneAttr) == MailQuote(lead: "\n", newest: String(oneAttr.dropFirst()), older: nil))
        let twoAttr = "On Jun 9, Bob <bob@x.com> wrote:\n> latest\n> > On Jun 8, Al <al@x.com> wrote:\n> > older"
        let seg = preprocess(rawSuffix: twoAttr)
        check("seg: ≥2 attributions → older non-nil", seg?.older != nil)
        check("seg: ≥2 → newest contains latest body", seg?.newest.contains("latest") == true)
        check("seg: ≥2 → older contains older body", seg?.older?.contains("older") == true)
        check("seg: ≥2 → newest excludes older body", seg?.newest.contains("> > older") == false)
        check("seg: ≥2 → lossless reassembly", (seg?.lead ?? "x") + (seg?.newest ?? "") + (seg?.older ?? "") == twoAttr)
        let threeAttr = twoAttr + "\n> > > On Jun 7, Cy <cy@x.com> wrote:\n> > > oldest"
        let seg3 = preprocess(rawSuffix: threeAttr)
        check("seg: 3 attributions → older spans 2nd+3rd",
              seg3?.newest.contains("latest") == true
              && seg3?.older?.contains("On Jun 8") == true
              && seg3?.older?.contains("On Jun 7") == true)

        // Lead handling: user's own draft text above the quote is NEVER `newest`
        let draftLead = "rest of my paragraph.\n\nThanks,\nLeo\n\nOn Jun 9, Bob <bob@x.com> wrote:\n> hi"
        let segLead = preprocess(rawSuffix: draftLead)
        check("seg: draft lead captured as lead, not newest",
              segLead?.lead.contains("Thanks") == true && segLead?.newest.hasPrefix("On Jun 9") == true)
        check("seg: draft-lead lossless",
              (segLead?.lead ?? "") + (segLead?.newest ?? "") + (segLead?.older ?? "") == draftLead)
        // Head anchoring: detect fires only when caret sits against the quote
        check("detect: draft text before quote does not fire",
              !detectsQuoteAtSuffixHead("more of my draft\nOn Jun 9, Bob <bob@x.com> wrote:"))
        check("detect: whitespace-only lead fires",
              detectsQuoteAtSuffixHead("\n\nOn Jun 9, Bob <bob@x.com> wrote:"))

        // Outlook desktop (Word engine) joins header lines with VERTICAL TABS (\u{0B})
        let vtBlock = "\n\nFrom: Anupam <a@example.com>\u{0B}Date: Monday, June 8, 2026\u{0B}To: Xin <x@x.edu>\nApologies for the late reply.\n\nOn Sun, Jun 7, 2026 at 1:00 PM Xin <x@x.edu> wrote:\nolder body"
        check("attr: VT-joined Outlook block detected at head", detectsQuoteAtSuffixHead(vtBlock))
        let segVT = preprocess(rawSuffix: vtBlock)
        check("seg: VT block is newest, not lead",
              segVT?.lead == "\n\n" && segVT?.newest.hasPrefix("From: Anupam") == true
              && segVT?.newest.contains("Apologies") == true)
        check("seg: VT case — older starts at On-line",
              segVT?.older?.hasPrefix("On Sun, Jun 7") == true)

        // 163/NetEase webmail: `At <timestamp>, "Name" <addr> wrote:` lead
        let attr163 = "Thanks!\n\nAt 2025-09-04 05:51:46, \"Apple Support\" <support@example.com> wrote:\nHello Xin,\nPlease upload the documents."
        let seg163 = preprocess(rawSuffix: attr163)
        check("seg: 163 'At…wrote:' splits at attribution",
              seg163?.lead == "Thanks!\n\n" && seg163?.newest.hasPrefix("At 2025-09-04") == true
              && seg163?.older == nil)
        check("attr: prose 'at the meeting we wrote:' without email no match",
              preprocess(rawSuffix: "at the meeting we wrote:\nnotes") == nil)
        check("attr: 'At…' without wrote: terminal no match",
              preprocess(rawSuffix: "At 5pm <a@example.com> we will meet\nbody") == nil)

        Log.info("[MailReplySelfCheck] \(pass) passed, \(fail) failed")
    }
}
#endif
