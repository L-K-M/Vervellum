import XCTest
#if canImport(VervellumKit)
// Linux: the portable code is its own SwiftPM module.
@testable import VervellumKit
#else
// macOS: it is compiled straight into the app target, so there is no separate module.
@testable import Vervellum
#endif

/// The fallback chain: which provider answers, when the turn moves on, and — just as
/// important — when it must not.
///
/// No network anywhere. `ModelChain.perform` hands the body a `ChatCompletionsClient`,
/// and a client is identified well enough by its `model`, so a test body can decide to
/// fail or succeed per provider and the chain's own logic is what is under test.
final class ModelChainTests: XCTestCase {

    private func trace() -> ResearchTrace { ResearchTrace(sink: SilentLog()) }

    private func profile(_ name: String, model: String? = nil) -> ModelProfile {
        ModelProfile.new(name: name, endpoint: "https://\(name).example.com/v1",
                         model: model ?? name)
    }

    private func chain(_ profiles: [ModelProfile]) -> ModelChain {
        ModelChain(profiles: profiles, keys: [:], trace: trace())
    }

    // MARK: The head

    /// The picker says which provider answers. A chain that started anywhere else would
    /// make the picker wrong.
    func testAsksTheFirstProviderWhenItAnswers() async throws {
        let profiles = [profile("alpha"), profile("beta")]
        var asked: [String] = []
        let result = try await chain(profiles).perform("Plan") { client in
            asked.append(client.model)
            return "ok"
        }
        XCTAssertEqual(result, "ok")
        XCTAssertEqual(asked, ["alpha"], "the second provider must not be contacted at all")
    }

    // MARK: Falling back

    func testMovesToTheNextProviderWhenTheFirstFails() async throws {
        let profiles = [profile("alpha"), profile("beta")]
        var asked: [String] = []
        let result = try await chain(profiles).perform("Plan") { client in
            asked.append(client.model)
            if client.model == "alpha" { throw ResearchError.connectionFailed }
            return client.model
        }
        XCTAssertEqual(result, "beta")
        XCTAssertEqual(asked, ["alpha", "beta"])
    }

    /// A rejected key is a configuration failure, not weather — and it is exactly the
    /// state a second provider exists to cover.
    func testARejectedKeyIsWorthAnotherProvider() async throws {
        let profiles = [profile("alpha"), profile("beta")]
        var asked: [String] = []
        let result = try await chain(profiles).perform("Plan") { client in
            asked.append(client.model)
            if client.model == "alpha" { throw ResearchError.rejectedCredential(401) }
            return client.model
        }
        XCTAssertEqual(result, "beta")
        // Who was contacted, not only who answered: returning "beta" is also what a chain
        // that retried the rejected key first, or skipped a spare, would return.
        XCTAssertEqual(asked, ["alpha", "beta"], "left exactly once, for the next one")
    }

    /// A provider that died mid-sentence has already streamed text into the turn. The
    /// next one starts from the beginning, so the fragment has to go first.
    func testRunsTheResetBeforeEachRetryAndNotBeforeTheFirstTry() async throws {
        // Three, because with two there is exactly one retry and "before each retry" is
        // indistinguishable from "once, ever" — a one-shot flag would have passed.
        let profiles = [profile("alpha"), profile("beta"), profile("gamma")]
        var resets = 0
        var seenAtEntry: [Int] = []
        _ = try await chain(profiles).perform("Answer", beforeRetry: { resets += 1 }) { client in
            seenAtEntry.append(resets)
            if client.model != "gamma" { throw ResearchError.streamInterrupted }
            return client.model
        }
        XCTAssertEqual(seenAtEntry, [0, 1, 2],
                       "no reset before the first provider, one before each later one")
        XCTAssertEqual(resets, 2)
    }

    // MARK: Not falling back

    /// A Stop is a Stop. Re-asking a second provider would be the opposite of what the
    /// user just pressed, and would spend a request doing it.
    func testACancellationIsNeverRetriedOnAnotherProvider() async {
        let profiles = [profile("alpha"), profile("beta")]
        var asked: [String] = []
        do {
            _ = try await chain(profiles).perform("Plan") { client in
                asked.append(client.model)
                throw ResearchError.cancelled
            }
            XCTFail("expected the cancellation to propagate")
        } catch let error as ResearchError {
            XCTAssertEqual(error, ResearchError.cancelled, "and unwrapped, not relabelled")
        } catch {
            XCTFail("expected a ResearchError, got \(error)")
        }
        XCTAssertEqual(asked, ["alpha"])
    }

    /// The reset exists to clear a fragment before the next provider starts writing over
    /// it. A Stop starts no next provider, so it must not run — and nothing pinned that:
    /// an implementation that fired it from a `defer`, or on any exit from the attempt,
    /// would pass every other test here while wiping the turn for no reason.
    func testACancellationDoesNotRunTheReset() async {
        let profiles = [profile("alpha"), profile("beta")]
        var resets = 0
        do {
            _ = try await chain(profiles).perform("Answer", beforeRetry: { resets += 1 }) { _ in
                throw ResearchError.cancelled
            }
            XCTFail("expected the cancellation to propagate")
        } catch let error as ResearchError {
            XCTAssertEqual(error, ResearchError.cancelled)
        } catch {
            XCTFail("expected a ResearchError, got \(error)")
        }
        XCTAssertEqual(resets, 0, "nothing was retried, so nothing was reset")
    }

    /// An unencodable payload would fail identically at every provider, so the chain has
    /// to treat it as terminal rather than as this provider's bad day. What is pinned
    /// here is that classification: the measurement itself happens where the payload is
    /// built, and the error arrives from the body like any other.
    func testAnUnencodableContextIsNeverRetriedOnAnotherProvider() async {
        let profiles = [profile("alpha"), profile("beta")]
        var asked: [String] = []
        do {
            _ = try await chain(profiles).perform("Plan") { client in
                asked.append(client.model)
                throw ResearchError.invalidContext
            }
            XCTFail("expected the error to propagate")
        } catch let error as ResearchError {
            XCTAssertEqual(error, ResearchError.invalidContext)
        } catch {
            XCTFail("expected a ResearchError, got \(error)")
        }
        XCTAssertEqual(asked, ["alpha"])
    }

    // MARK: Staying put

    /// Re-testing a provider that already failed would cost a timeout per stage, and a
    /// turn whose stages alternated between two models would be incoherent.
    func testStaysOnTheProviderItMovedToForLaterCalls() async throws {
        let profiles = [profile("alpha"), profile("beta")]
        let subject = chain(profiles)
        _ = try await subject.perform("Plan") { client in
            if client.model == "alpha" { throw ResearchError.connectionFailed }
            return client.model
        }
        var askedNext: [String] = []
        let answer = try await subject.perform("Answer") { client in
            askedNext.append(client.model)
            return client.model
        }
        XCTAssertEqual(answer, "beta")
        XCTAssertEqual(askedNext, ["beta"], "the failed provider is not tried again this turn")
    }

    /// The same client instance, because it remembers whether this endpoint rejected the
    /// optional request parameters — rediscovering that on each of a turn's three calls
    /// is what that memory exists to avoid.
    func testReusesOneClientPerProviderAcrossCalls() async throws {
        let profiles = [profile("alpha")]
        let subject = chain(profiles)
        let first = try await subject.perform("Plan") { ObjectIdentifier($0) }
        let second = try await subject.perform("Answer") { ObjectIdentifier($0) }
        XCTAssertEqual(first, second)
    }

    // MARK: Half-configured providers

    /// A spare the user is halfway through adding must not fail a turn the providers
    /// around it can serve.
    func testSkipsAProviderThatIsNotConfigured() async throws {
        let profiles = [profile("alpha"),
                        ModelProfile.new(name: "blank", endpoint: "", model: ""),
                        profile("gamma")]
        var asked: [String] = []
        let result = try await chain(profiles).perform("Plan") { client in
            asked.append(client.model)
            if client.model == "alpha" { throw ResearchError.connectionFailed }
            return client.model
        }
        XCTAssertEqual(result, "gamma")
        XCTAssertEqual(asked, ["alpha", "gamma"])
    }

    /// An endpoint that is not HTTPS never becomes a request. Asserted on what was
    /// asked, not only on what came back: a result of "gamma" would also be produced by
    /// a chain that contacted the insecure endpoint first and moved on.
    func testSkipsAProviderWhoseEndpointIsUnusable() async throws {
        let profiles = [profile("alpha"),
                        ModelProfile.new(name: "insecure", endpoint: "http://elsewhere.example.com",
                                         model: "insecure"),
                        profile("gamma")]
        var asked: [String] = []
        let result = try await chain(profiles).perform("Plan") { client in
            asked.append(client.model)
            if client.model == "alpha" { throw ResearchError.connectionFailed }
            return client.model
        }
        XCTAssertEqual(result, "gamma")
        XCTAssertEqual(asked, ["alpha", "gamma"],
                       "the insecure endpoint must never be contacted")
    }

    // MARK: Which provider answered

    /// The head answering is the ordinary case, and it has to be recorded too — the
    /// badge that names the model was blank on every turn that went right.
    func testTheHeadIsRecordedWhenItAnswers() async throws {
        let subject = chain([profile("alpha"), profile("beta")])
        _ = try await subject.perform("Answer") { $0.model }
        XCTAssertEqual(subject.lastAnswered?.model, "alpha")
    }

    /// This follows the last *successful* stage, not the last announcement — and it does
    /// keep moving, which is the whole reason the runner reads it immediately after the
    /// answering stage rather than at the end of the turn. Pinned here so nobody
    /// mistakes it for a value that freezes itself; `perform` clears it on the way in, so
    /// reading late gets nothing rather than the wrong thing.
    func testTheRecordFollowsEachStageThatSucceeds() async throws {
        let subject = chain([profile("alpha"), profile("beta")])
        _ = try await subject.perform("Answer") { $0.model }
        XCTAssertEqual(subject.lastAnswered?.model, "alpha")

        // The assess stage falls through to beta, as it may.
        _ = try await subject.perform("Assess") { client in
            if client.model == "alpha" { throw ResearchError.connectionFailed }
            return client.model
        }
        XCTAssertEqual(subject.lastAnswered?.model, "beta",
                       "beta answered the assess stage, so it is what that stage recorded")
    }

    /// A provider reached by falling through is the one that answered.
    func testTheSpareIsRecordedWhenTheHeadFails() async throws {
        let subject = chain([profile("alpha"), profile("beta")])
        _ = try await subject.perform("Answer") { client in
            if client.model == "alpha" { throw ResearchError.connectionFailed }
            return client.model
        }
        XCTAssertEqual(subject.lastAnswered?.model, "beta")
    }

    /// A skipped *head* reaches the next provider without any failure being caught: the
    /// loop steps past a profile it cannot build a client for and never enters the catch.
    /// Recording on the failure path alone left that answer under the selection's name —
    /// the silent substitution the type's third rule forbids — so this is the case that
    /// says why `lastAnswered` is written at the point of success.
    func testASkippedHeadStillLeavesTheSpareRecorded() async throws {
        let profiles = [ModelProfile.new(name: "blank", endpoint: "", model: ""),
                        profile("beta")]
        let subject = chain(profiles)
        let result = try await subject.perform("Plan") { $0.model }
        XCTAssertEqual(result, "beta")
        XCTAssertEqual(subject.lastAnswered?.model, "beta")
        XCTAssertNotEqual(subject.lastAnswered?.id, subject.head?.id,
                          "the head did not answer, and the notice hangs on that comparison")
    }

    /// A skip in the *middle* of the chain, which is the head-skip case one step over:
    /// alpha fails, the blank spare is never contacted, and gamma answers. Recording when
    /// the chain *moves on* rather than when a provider is used would name beta over
    /// gamma's words, and every other test here would stay green.
    ///
    /// This arrived on `claude/model-fallback-chain` as an `onSwitch` test; the hook is
    /// gone on this branch, so it asks the record instead. The property it pins is the
    /// same one.
    func testASkipMidChainStillLeavesTheProviderThatAnsweredRecorded() async throws {
        let profiles = [profile("alpha"),
                        ModelProfile.new(name: "blank", endpoint: "", model: ""),
                        profile("gamma")]
        let subject = chain(profiles)
        let result = try await subject.perform("Plan") { client in
            if client.model == "alpha" { throw ResearchError.connectionFailed }
            return client.model
        }
        XCTAssertEqual(result, "gamma")
        XCTAssertEqual(subject.lastAnswered?.model, "gamma")
        XCTAssertNotEqual(subject.lastAnswered?.id, subject.head?.id,
                          "the head did not answer, and the notice hangs on that comparison")
    }

    /// Nothing answered, so there is nothing to attribute — a turn that failed must not
    /// name a provider as having produced words it never produced.
    func testNothingIsRecordedWhenEveryProviderFails() async {
        let subject = chain([profile("alpha"), profile("beta")])
        _ = try? await subject.perform("Answer") { _ in
            throw ResearchError.connectionFailed
        }
        XCTAssertNil(subject.lastAnswered)
    }

    /// The head is the selection by construction, and comparing against it is how the
    /// runner decides whether the answer needs a fallback note at all.
    func testTheHeadIsTheSelection() {
        XCTAssertEqual(chain([profile("alpha"), profile("beta")]).head?.model, "alpha")
        XCTAssertNil(chain([]).head)
    }

    /// A stage that answered nothing must not leave the previous stage's provider behind
    /// for a late reader to mistake for its own. Nil is a blank badge and a tripped
    /// assertion; a stale value is one provider's name on another's words, silently.
    func testAFailedStageDoesNotInheritTheEarlierRecord() async throws {
        let subject = chain([profile("alpha")])
        _ = try await subject.perform("Answer") { $0.model }
        XCTAssertEqual(subject.lastAnswered?.model, "alpha")

        _ = try? await subject.perform("Assess") { _ in
            throw ResearchError.connectionFailed
        }
        XCTAssertNil(subject.lastAnswered)
    }

    // MARK: Exhaustion

    /// The first error is the selected provider's, and that is the one the user will act
    /// on — not whatever the least-preferred spare happened to say.
    func testReportsHowManyWereTriedAndKeepsTheFirstReason() async {
        let profiles = [profile("alpha"), profile("beta"), profile("gamma")]
        do {
            _ = try await chain(profiles).perform("Plan") { client in
                // Distinguishable per provider: with beta and gamma failing identically,
                // the assertion below would pass whether the chain keeps the first
                // reason or concatenates every reason it collected.
                switch client.model {
                case "alpha": throw ResearchError.rejectedCredential(401)
                case "beta": throw ResearchError.rejectedCredential(403)
                default: throw ResearchError.connectionFailed
                }
            }
            XCTFail("expected the chain to fail")
        } catch let error as ResearchError {
            XCTAssertTrue(error.message.contains("All 3 model providers failed"), error.message)
            XCTAssertTrue(error.message.contains("HTTP 401"),
                          "the selected provider's reason is the actionable one: \(error.message)")
            XCTAssertFalse(error.message.contains("HTTP 403"),
                           "a later provider's reason must not displace the first: \(error.message)")
        } catch {
            XCTFail("expected a ResearchError, got \(error)")
        }
    }

    /// A provider that was skipped was never tried, so it must not be counted. One
    /// usable provider that fails is a single-provider failure however many half-written
    /// spares sit beside it, and "All 2 model providers failed" after one attempt would
    /// be both wrong and unhelpful.
    func testASkippedProviderDoesNotCountAsTried() async {
        let profiles = [ModelProfile.new(name: "blank", endpoint: "", model: ""),
                        profile("beta")]
        do {
            _ = try await chain(profiles).perform("Plan") { _ in
                throw ResearchError.connectionFailed
            }
            XCTFail("expected the chain to fail")
        } catch let error as ResearchError {
            XCTAssertEqual(error, ResearchError.connectionFailed,
                           "one provider tried, so its own error — not an exhaustion count")
        } catch {
            XCTFail("expected a ResearchError, got \(error)")
        }
    }

    /// With one provider the message must read exactly as it did before there was a
    /// chain at all — "All 1 model providers failed" would be a regression in prose.
    func testASingleProvidersFailureIsReportedUnchanged() async {
        do {
            _ = try await chain([profile("alpha")]).perform("Plan") { _ in
                throw ResearchError.connectionFailed
            }
            XCTFail("expected the chain to fail")
        } catch let error as ResearchError {
            XCTAssertEqual(error, ResearchError.connectionFailed)
            // The prose, which is what the comment above is actually about. Equality
            // alone would keep passing if `ResearchError` ever compared something
            // narrower than its message.
            XCTAssertFalse(error.message.contains("All 1"),
                           "one provider's failure keeps its own wording: \(error.message)")
        } catch {
            XCTFail("expected a ResearchError, got \(error)")
        }
    }

    func testAnEmptyChainSaysNothingIsConfigured() async {
        do {
            _ = try await chain([]).perform("Plan") { _ in "unreachable" }
            XCTFail("expected the chain to fail")
        } catch let error as ResearchError {
            XCTAssertTrue(error.message.contains("No model provider is configured"), error.message)
        } catch {
            XCTFail("expected a ResearchError, got \(error)")
        }
    }

    /// A different sentence from the empty chain's, because it is a different repair.
    /// Both cases reach the same place — nothing was ever attempted — but a reader
    /// looking at two providers in Settings who is told none is configured has been sent
    /// to look for something that is on the screen in front of them.
    func testAChainOfUnusableProvidersSaysTheyCouldNotBeUsed() async {
        let profiles = [ModelProfile.new(name: "blank", endpoint: "", model: ""),
                        ModelProfile.new(name: "unnamed",
                                         endpoint: "https://alpha.example.com/v1", model: "")]
        do {
            _ = try await chain(profiles).perform("Plan") { _ in "unreachable" }
            XCTFail("expected the chain to fail")
        } catch let error as ResearchError {
            XCTAssertTrue(error.message.contains("No model provider could be used"), error.message)
            XCTAssertFalse(error.message.contains("is configured"),
                           "two configured providers must not be reported as none: \(error.message)")
        } catch {
            XCTFail("expected a ResearchError, got \(error)")
        }
    }
}
