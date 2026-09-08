import Foundation

/// The configured model providers, tried in order until one answers.
///
/// A turn used to be tied to one endpoint: if it was rate-limited, down, or holding a
/// key that had expired, the turn failed and the question had to be re-typed against a
/// provider chosen by hand. A chain makes the second provider the app's job instead of
/// the user's.
///
/// Three rules shape it, and all three are about not lying to the reader about where an
/// answer came from:
///
/// * **The selection is always the head.** The picker says which provider answers, so a
///   chain starting anywhere else would make the picker wrong. Fallback is a recovery
///   path, never a load balancer.
/// * **Once it has moved on, it stays.** A later stage does not go back and re-try a
///   provider that already failed this turn. Re-testing a dead endpoint before every
///   call costs a timeout per stage, and a turn whose plan came from one model and
///   whose answer came from another is confusing enough without it alternating.
/// * **A switch is always visible.** `onSwitch` fires before any provider but the head
///   is used — not on the failure path, since a provider can be reached by skipping an
///   unusable head rather than by catching a failure — so the runner can record the
///   model that is really answering and post a notice. A silent substitution would put
///   one provider's name on another's words, and this app records the model on every
///   turn precisely because that attribution matters.
///
/// Clients are built lazily rather than up front. Constructing one is cheap, but
/// *validating* an endpoint is where a half-configured second profile would otherwise
/// throw during setup and take down a turn the first provider could have served alone.
final class ModelChain {

    private let profiles: [ModelProfile]
    private let keys: [UUID: String]
    private let trace: ResearchTrace
    private let transport: HTTPTransport

    /// How far down the chain this turn has already moved.
    private var index = 0

    /// The client for each provider, created on first use and then kept.
    ///
    /// Kept rather than rebuilt because `ChatCompletionsClient` remembers whether its
    /// endpoint rejected the optional request parameters — paying that discovery again
    /// on each of a turn's three calls is exactly what that memory exists to avoid.
    private var built: [UUID: ChatCompletionsClient] = [:]

    /// Invoked with the profile now answering, whenever the chain moves on. Not called
    /// for the head — that one is the selection the user made, and announcing it as a
    /// change would be noise on every turn.
    var onSwitch: ((ModelProfile) -> Void)?

    /// The profile already announced through `onSwitch`.
    ///
    /// A turn calls `perform` once per stage and `index` persists across those calls, so
    /// without this the provider that answered the plan would be announced again for the
    /// search and again for the answer.
    private var announcedID: UUID?

    init(profiles: [ModelProfile],
         keys: [UUID: String],
         trace: ResearchTrace,
         transport: HTTPTransport = .shared) {
        self.profiles = profiles
        self.keys = keys
        self.trace = trace
        self.transport = transport
    }

    // MARK: Running

    /// Runs `body` against the current provider, moving down the chain if it fails.
    ///
    /// `beforeRetry` runs after a failure and before the next provider is tried. It is
    /// how the answer stage discards the half-streamed text of a provider that died
    /// mid-sentence: without it the next provider's answer would be appended to the
    /// dead one's fragment, producing a paragraph no model actually wrote.
    ///
    /// - Throws: the *first* provider's error when every provider fails, prefixed with
    ///   how many were tried. The first is the one the user selected and the one they
    ///   will act on; the last is whatever the least-preferred spare happened to say.
    func perform<T>(_ label: String,
                    beforeRetry: (() -> Void)? = nil,
                    _ body: (ChatCompletionsClient) async throws -> T) async throws -> T {
        var firstError: ResearchError?
        var attempted = 0

        while index < profiles.count {
            let profile = profiles[index]
            guard let client = client(for: profile) else {
                // An unusable endpoint or an empty model name. Not an error to report on
                // its own: a spare the user is halfway through configuring must not fail
                // a turn the providers around it can serve.
                trace.log("\(label): skipping \(profile.displayName), it is not configured")
                index += 1
                continue
            }
            announce(profile)
            attempted += 1
            do {
                return try await body(client)
            } catch let error as ResearchError where error.isWorthAnotherProvider {
                if firstError == nil { firstError = error }
                trace.warn("\(label) failed on \(profile.displayName): \(error.message)")
                index += 1
                guard let next = nextUsableProfile() else { break }
                beforeRetry?()
                trace.log("\(label): trying \(next.displayName)")
            }
        }

        // No provider ever ran, so nothing failed: the chain was empty, or every profile
        // in it was too incomplete to build a request from.
        guard let firstError else {
            throw ResearchError("No model provider is configured. Check Settings ▸ Providers.")
        }
        guard attempted > 1 else { throw firstError }
        throw ResearchError("All \(attempted) model providers failed. " + firstError.message)
    }

    /// Announces `profile` unless it is the selection, or has been announced already.
    ///
    /// At the point of use rather than on the failure path, because a provider can start
    /// answering without any failure having been caught: if the *head* cannot build a
    /// client — an endpoint that will not parse, an empty model name — the loop skips it
    /// and the next profile answers having never passed through the catch. Announcing
    /// there left that answer recorded under the selection's name with no notice, which
    /// is exactly the silent substitution this type's third rule forbids.
    ///
    /// Latent rather than live today: `ResearchRunner` checks the selected provider's
    /// endpoint and model name before building a chain at all, so an unusable head is
    /// rejected earlier. That is a precondition in another file, and this type's promise
    /// should not depend on it.
    private func announce(_ profile: ModelProfile) {
        guard profile.id != profiles.first?.id, announcedID != profile.id else { return }
        announcedID = profile.id
        onSwitch?(profile)
    }

    // MARK: Links

    /// Advances past any profile that cannot be reached and returns the next that can.
    private func nextUsableProfile() -> ModelProfile? {
        while index < profiles.count {
            let profile = profiles[index]
            if client(for: profile) != nil { return profile }
            trace.log("Skipping \(profile.displayName), it is not configured")
            index += 1
        }
        return nil
    }

    /// The client for `profile`, or nil when the profile cannot be reached at all.
    private func client(for profile: ModelProfile) -> ChatCompletionsClient? {
        if let existing = built[profile.id] { return existing }
        guard let url = ProviderSettings.chatCompletionsURL(from: profile.endpoint) else { return nil }
        let model = profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return nil }
        let client = ChatCompletionsClient(url: url, model: model, apiKey: keys[profile.id],
                                           trace: trace, transport: transport)
        built[profile.id] = client
        return client
    }
}
