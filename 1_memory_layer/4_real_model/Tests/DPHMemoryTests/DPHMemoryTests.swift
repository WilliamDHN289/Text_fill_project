import Testing
import Foundation
@testable import DPHMemory

/// Config used by most tests: prefetch/persistence off so tests are
/// deterministic and hermetic (no App Support writes).
private func testConfig() -> DPHMConfig {
    var c = DPHMConfig()
    c.prefetchEnabled = false
    c.persistenceEnabled = false
    return c
}

private func makeMemory(_ config: DPHMConfig = testConfig()) -> DPHMMemory {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("dphm-test-\(UUID().uuidString).json")
    return DPHMMemory(config: config, storeURL: tmp, loadPersisted: false)
}

private func approxEqual(_ a: Double, _ b: Double, tolerance: Double = 1e-9) -> Bool {
    abs(a - b) <= tolerance
}

// MARK: - Tokenizer

@Suite struct TokenizerTests {
    @Test func english() {
        #expect(DPHMTokenizer.tokenize("Please find attached, thanks!")
                == ["please", "find", "attached", ",", "thanks", "!"])
    }

    @Test func contractionsAndCompounds() {
        #expect(DPHMTokenizer.tokenize("don't over-think it") == ["don't", "over-think", "it"])
    }

    @Test func cjkSplitsPerCharacter() {
        #expect(DPHMTokenizer.tokenize("我想说 hello 世界")
                == ["我", "想", "说", "hello", "世", "界"])
    }

    @Test func detokenizeEnglish() {
        #expect(DPHMTokenizer.detokenize(["please", "find", "attached", ",", "thanks"])
                == "please find attached, thanks")
    }

    @Test func detokenizeCJKNoSpaces() {
        #expect(DPHMTokenizer.detokenize(["我", "想", "说", "hello"]) == "我想说hello")
    }
}

// MARK: - Decayed n-gram trie

@Suite struct DecayedNGramTrieTests {
    @Test func observeAndTopContinuations() {
        let trie = DecayedNGramTrie(order: 3, halfLifeSeconds: 3600)
        let t0 = 1000.0
        trie.observe(["please", "find", "attached"], now: t0)
        trie.observe(["please", "find", "attached"], now: t0 + 1)
        trie.observe(["please", "find", "below"], now: t0 + 2)

        let top = trie.topContinuations(context: ["please", "find"], k: 5, now: t0 + 3)
        #expect(top.first?.token == "attached")
        #expect(top.count == 2)
    }

    @Test func prefixFilter() {
        let trie = DecayedNGramTrie(order: 2, halfLifeSeconds: 3600)
        trie.observe(["find", "attached"], now: 0)
        trie.observe(["find", "below"], now: 0)
        let top = trie.topContinuations(context: ["find"], prefix: "att", now: 1)
        #expect(top.map(\.token) == ["attached"])
    }

    @Test func stupidBackoff() {
        let trie = DecayedNGramTrie(order: 3, halfLifeSeconds: 3600, backoffAlpha: 0.4)
        trie.observe(["b", "c"], now: 0)
        // Context ["a","b"] never seen → backs off to ["b"] with an α penalty.
        let backedOff = trie.score(context: ["a", "b"], candidate: "c", now: 1)
        let direct = trie.score(context: ["b"], candidate: "c", now: 1)
        #expect(approxEqual(backedOff, direct + log(0.4)))
        // Unknown token bottoms out at the floor.
        #expect(trie.score(context: ["b"], candidate: "zzz", now: 1) == DecayedNGramTrie.floorLogScore)
    }

    @Test func exponentialDecayAndForgetting() {
        let halfLife = 100.0
        let trie = DecayedNGramTrie(order: 2, halfLifeSeconds: halfLife)
        trie.observe(["hello", "world"], now: 0)
        // One half-life later a single-count entry has effective weight 0.5.
        #expect(approxEqual(trie.decayedCount(context: "hello", next: "world", now: halfLife), 0.5))
        // Recurring pattern survives pruning; one-shot noise does not.
        // At t = 5·halfLife: one-shot (count 1 @ t=0) → 1·2⁻⁵ ≈ 0.031 < 0.05
        // (pruned); recurring (1.5 effective @ t=halfLife) → 1.5·2⁻⁴ ≈ 0.094
        // > 0.05 (survives).
        trie.observe(["hello", "world"], now: halfLife)
        trie.observe(["one", "shot"], now: 0)
        trie.prune(floor: 0.05, now: 5 * halfLife)
        #expect(trie.decayedCount(context: "one", next: "shot", now: 5 * halfLife) == 0)
        #expect(trie.decayedCount(context: "hello", next: "world", now: 5 * halfLife) > 0)
    }

    @Test func snapshotRestoreRoundTrip() {
        let trie = DecayedNGramTrie(order: 3, halfLifeSeconds: 3600)
        trie.observe(["please", "find", "attached"], now: 100)
        trie.observe(["please", "find", "below"], now: 200)

        let copy = DecayedNGramTrie(order: 3, halfLifeSeconds: 3600)
        copy.restore(trie.snapshot())

        let now = 300.0
        let probes: [([String], String)] = [(["please", "find"], "attached"),
                                            (["find"], "below"),
                                            ([], "please")]
        for (ctx, cand) in probes {
            #expect(approxEqual(copy.score(context: ctx, candidate: cand, now: now),
                                trie.score(context: ctx, candidate: cand, now: now)),
                    "score mismatch for \(ctx) → \(cand)")
        }
    }
}

// MARK: - Config / YAML

@Suite struct ConfigTests {
    @Test func defaultTemplateParsesToDefaults() {
        let parsed = DPHMConfig.parse(yaml: DPHMConfig.defaultYAML)
        let defaults = DPHMConfig()
        #expect(parsed.enabled == defaults.enabled)
        #expect(parsed.maxSuggestionWords == defaults.maxSuggestionWords)
        #expect(approxEqual(parsed.minDisplayScore, defaults.minDisplayScore))
        #expect(approxEqual(parsed.lambdaSession, defaults.lambdaSession))
        #expect(approxEqual(parsed.longHalfLifeDays, defaults.longHalfLifeDays))
        #expect(parsed.rerankCloudCandidates == defaults.rerankCloudCandidates)
        #expect(approxEqual(parsed.weightAcceptedSuggestion, defaults.weightAcceptedSuggestion))
        #expect(approxEqual(parsed.saveIntervalSeconds, defaults.saveIntervalSeconds))
    }

    @Test func overrides() {
        let yaml = """
        enabled: false
        hot_path:
          max_suggestion_words: 7   # inline comment
          min_display_score: -2.0
        fusion:
          rerank_cloud_candidates: true
        session:
          half_life_minutes: 5
        """
        let c = DPHMConfig.parse(yaml: yaml)
        #expect(c.enabled == false)
        #expect(c.maxSuggestionWords == 7)
        #expect(approxEqual(c.minDisplayScore, -2.0))
        #expect(c.rerankCloudCandidates == true)
        #expect(approxEqual(c.sessionHalfLifeMinutes, 5))
        // Untouched keys keep defaults.
        #expect(c.topK == DPHMConfig().topK)
    }
}

// MARK: - End-to-end habit learning

@Suite struct DPHMMemoryEndToEndTests {

    @Test func learnsPhraseAndSuggestsAtWordBoundary() {
        let m = makeMemory()
        for _ in 0..<5 {
            m.commitSentMessage("please find attached the report")
        }
        m.flushConsolidation()

        let s = m.suggest(bufferText: "ok sure, please find ")
        #expect(s != nil, "expected a habit suggestion after 5 recurrences")
        #expect(s?.text.hasPrefix("attached") == true, "got: '\(s?.text ?? "")' (\(s?.source ?? ""))")
    }

    @Test func midWordCompletionDropsTypedChars() {
        let m = makeMemory()
        for _ in 0..<5 {
            m.commitSentMessage("please find attached the report")
        }
        m.flushConsolidation()

        let s = m.suggest(bufferText: "please find att")
        #expect(s != nil)
        #expect(s?.text.hasPrefix("ached") == true,
                "mid-word completion should drop 'att', got: '\(s?.text ?? "")'")
    }

    @Test func habitLexiconPromotion() {
        let m = makeMemory()
        // PMI needs a diluted unigram background — a corpus of only the
        // target phrase makes p(kind)·p(regards) as large as p(kind regards)
        // and PMI collapses. Mix in varied filler messages like real usage.
        let filler = ["let me check the numbers today", "can we move the sync",
                      "that build is green now", "lunch first then review",
                      "the client call went well", "see the doc for details",
                      "not sure about that yet", "will push the fix soon",
                      "give me ten minutes", "sounds good to me"]
        for msg in filler { m.commitSentMessage(msg) }
        for _ in 0..<6 {
            m.commitSentMessage("kind regards, harry")
        }
        m.flushConsolidation()
        #expect(m.stats.habitCount > 0, "recurring collocations should be promoted")
    }

    @Test func noSuggestionFromUnseenContext() {
        let m = makeMemory()
        m.commitSentMessage("hello world")
        m.flushConsolidation()
        #expect(m.suggest(bufferText: "quantum chromodynamics is ") == nil)
    }

    @Test func sessionCacheLearnsWithinSession() {
        let m = makeMemory()
        // No commits — only word-boundary observations (session trie).
        for _ in 0..<4 {
            m.onWordBoundary(bufferText: "the quarterly revenue numbers ")
        }
        let s = m.suggest(bufferText: "let me check the quarterly ")
        #expect(s != nil, "session cache should serve recent burst vocabulary")
        #expect(s?.text.hasPrefix("revenue") == true, "got: '\(s?.text ?? "")'")
    }

    @Test func cjkHabit() {
        let m = makeMemory()
        for _ in 0..<5 {
            m.commitSentMessage("辛苦了，麻烦你了")
        }
        m.flushConsolidation()
        let s = m.suggest(bufferText: "好的，麻烦")
        #expect(s != nil)
        #expect(s?.text.hasPrefix("你") == true, "got: '\(s?.text ?? "")'")
    }

    @Test func rankCandidatesPromotesHabitualPhrasing() {
        var config = testConfig()
        config.rerankMargin = 0.5
        let m = makeMemory(config)
        for _ in 0..<8 {
            m.commitSentMessage("i will circle back tomorrow")
        }
        m.flushConsolidation()

        let ranked = m.rankCandidates(
            ["perhaps we could reconvene at a later date", "i will circle back tomorrow"],
            bufferText: "sounds good. ")
        #expect(ranked.first == "i will circle back tomorrow")
    }

    @Test func rankCandidatesKeepsPrimaryWithoutStrongSignal() {
        let m = makeMemory()
        let candidates = ["first choice from llm", "second", "third"]
        #expect(m.rankCandidates(candidates, bufferText: "hello ") == candidates)
    }

    @Test func disabledConfigIsInert() {
        var config = testConfig()
        config.enabled = false
        let m = makeMemory(config)
        m.commitSentMessage("please find attached the report")
        m.flushConsolidation()
        #expect(m.suggest(bufferText: "please find ") == nil)
        #expect(m.stats.commitCount == 0)
    }

    @Test func persistenceRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dphm-persist-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        var config = testConfig()
        config.persistenceEnabled = true
        let m1 = DPHMMemory(config: config, storeURL: url, loadPersisted: false)
        for _ in 0..<5 { m1.commitSentMessage("please find attached the report") }
        m1.flushConsolidation()
        m1.saveNow()
        #expect(FileManager.default.fileExists(atPath: url.path))

        let m2 = DPHMMemory(config: config, storeURL: url, loadPersisted: true)
        // Load is async on the io queue; poll briefly.
        var loaded: DPHMMemory.HabitSuggestion?
        for _ in 0..<50 {
            loaded = m2.suggest(bufferText: "please find ")
            if loaded != nil { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        #expect(loaded != nil, "restored store should serve the same habit")
        #expect(loaded?.text.hasPrefix("attached") == true)
    }

    @Test func speculativePrefetchPublishesOffHotPath() {
        var config = testConfig()
        config.prefetchEnabled = true
        config.prefetchDebounceMs = 30
        let m = makeMemory(config)
        m.commitSentMessage("the deployment pipeline failed again on staging")
        m.flushConsolidation()

        #expect(m.prefetchBuffer.isEmpty)
        m.onWordBoundary(bufferText: "about that deployment issue ")
        m.flushPrefetch()
        #expect(m.prefetchBuffer.boost("pipeline") > 0,
                "prefetch should boost tokens from lexically-related commits")
    }
}

// MARK: - Latency benchmark (the DPHM core claim: hot path p99 < 5 ms)

@Suite struct LatencyBenchmarkTests {

    /// Populate a memory with a realistic volume of history, then measure
    /// `suggest()` per-keystroke latency distribution.
    @Test func hotPathP99Under5ms() {
        let m = makeMemory()
        // ~500 committed messages built from a mixed EN/CJK vocabulary.
        var rng = SystemRandomNumberGenerator()
        let vocab = ["please", "find", "attached", "report", "meeting", "tomorrow",
                     "thanks", "regards", "circle", "back", "deploy", "pipeline",
                     "review", "budget", "quarterly", "revenue", "numbers", "team",
                     "schedule", "update", "client", "deadline", "morning", "sync",
                     "你好", "谢谢", "麻烦", "辛苦", "明天", "会议"]
        for _ in 0..<500 {
            let len = Int.random(in: 5...15, using: &rng)
            let msg = (0..<len).map { _ in vocab.randomElement(using: &rng)! }.joined(separator: " ")
            m.commitSentMessage(msg)
        }
        m.flushConsolidation()
        print("[bench] longTrieEntries=\(m.stats.longTrieEntries) habits=\(m.stats.habitCount)")

        // Simulate keystrokes: growing buffers ending at random positions.
        let buffers: [String] = (0..<2000).map { i in
            let len = Int.random(in: 3...10, using: &rng)
            var text = (0..<len).map { _ in vocab.randomElement(using: &rng)! }.joined(separator: " ")
            if i % 3 == 0 { text += " " }                      // word boundary
            else if i % 3 == 1 { text = String(text.dropLast(Int.random(in: 1...3, using: &rng))) } // mid-word
            return text
        }

        // Warm-up.
        for b in buffers.prefix(100) { _ = m.suggest(bufferText: b) }

        var samplesUs: [Double] = []
        samplesUs.reserveCapacity(buffers.count)
        var hits = 0
        for b in buffers {
            let t0 = DispatchTime.now().uptimeNanoseconds
            let s = m.suggest(bufferText: b)
            let t1 = DispatchTime.now().uptimeNanoseconds
            samplesUs.append(Double(t1 - t0) / 1000.0)
            if s != nil { hits += 1 }
        }
        samplesUs.sort()
        func pct(_ p: Double) -> Double { samplesUs[min(samplesUs.count - 1, Int(Double(samplesUs.count) * p))] }
        let mean = samplesUs.reduce(0, +) / Double(samplesUs.count)
        print(String(format: "[bench] suggest() n=%d hitRate=%.0f%% mean=%.1fµs p50=%.1fµs p95=%.1fµs p99=%.1fµs max=%.1fµs",
                     samplesUs.count, 100.0 * Double(hits) / Double(samplesUs.count),
                     mean, pct(0.50), pct(0.95), pct(0.99), samplesUs.last!))

        #expect(pct(0.99) < 5000, "hot-path p99 must stay under 5 ms")
    }

    /// Word-boundary event (session observe + prefetch enqueue) must also be
    /// hot-path cheap.
    @Test func wordBoundaryEventUnder1ms() {
        var config = testConfig()
        config.prefetchEnabled = true
        let m = makeMemory(config)
        let buffer = "the quick brown fox jumps over the lazy dog and keeps going "
        for _ in 0..<50 { m.onWordBoundary(bufferText: buffer) }  // warm-up

        var samplesUs: [Double] = []
        for _ in 0..<500 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            m.onWordBoundary(bufferText: buffer)
            let t1 = DispatchTime.now().uptimeNanoseconds
            samplesUs.append(Double(t1 - t0) / 1000.0)
        }
        samplesUs.sort()
        let p99 = samplesUs[Int(Double(samplesUs.count) * 0.99)]
        print(String(format: "[bench] onWordBoundary p50=%.1fµs p99=%.1fµs",
                     samplesUs[samplesUs.count / 2], p99))
        #expect(p99 < 1000, "word-boundary event p99 must stay under 1 ms")
    }
}
