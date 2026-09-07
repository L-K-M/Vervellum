import Foundation

/// A safe, user-facing failure.
///
/// The rule this type exists to enforce: **only messages Vervellum wrote itself are
/// ever shown or logged.** A provider's own exception text can carry the request
/// URL, an `Authorization` header, or an echoed response body — a gateway that
/// rejects a key sometimes quotes the key back. So every network path catches the
/// underlying error, discards it, and throws one of these instead.
struct ResearchError: LocalizedError, Equatable {
    let message: String

    init(_ message: String) { self.message = message }

    var errorDescription: String? { message }

    /// A short label safe to write to the log for a non-`ResearchError` failure:
    /// the type name only, never the description.
    static func safeLabel(for error: Error) -> String {
        (error as? ResearchError)?.message ?? String(describing: type(of: error))
    }

    /// Whether handing the turn to the next provider in the chain could plausibly help.
    ///
    /// The default is yes, and the exceptions are the two failures that are *Vervellum's
    /// own* rather than a provider's:
    ///
    /// * `cancelled` — the user pressed Stop. Re-asking a second provider would be the
    ///   opposite of what they just asked for, and would spend a request to do it.
    /// * `invalidContext` — the payload could not be encoded, or is larger than the
    ///   context budget. That is measured before a byte leaves the machine and is the
    ///   same at every endpoint, so every provider in the chain would fail identically.
    ///
    /// Everything else is worth another provider, including the ones that look like
    /// configuration rather than weather. A rejected key, a 404 from a wrong path, a
    /// model name the endpoint does not know: these are exactly the states a second
    /// provider exists to cover, and the whole point of a chain is that the turn
    /// survives one of them.
    var isWorthAnotherProvider: Bool {
        self != .cancelled && self != .invalidContext
    }

    // MARK: Common failures

    static let notConfigured = ResearchError(
        "Add your model endpoint and search key in Settings ▸ Providers before researching.")
    static let responseTooLarge = ResearchError(
        "The provider's response exceeded Vervellum's size limit and was discarded.")
    static let connectionFailed = ResearchError(
        "The provider connection failed or timed out. Please try again.")
    static let timedOut = ResearchError(
        "The provider did not answer in time and the request was abandoned. "
        + "A slow or local model may need a faster one, or a shorter question; otherwise try again.")
    static let invalidContext = ResearchError(
        "The request context is too large or cannot be encoded. Shorten the question or start a new thread.")
    static let invalidResponse = ResearchError(
        "The provider returned a response Vervellum could not read.")
    static let cancelled = ResearchError("Research cancelled.")
    static let streamInterrupted = ResearchError(
        "The model's reply ended without a valid completion or contained an error. "
        + "The answer may be incomplete. Try again.")

    /// HTTP 400. Named rather than generic because the client acts on it: a request
    /// carrying optional parameters is retried once without them before this reaches
    /// the user.
    static let badRequest = ResearchError(
        "The provider rejected the request (HTTP 400). Check the model name in the provider "
        + "settings; the model may also not accept a request parameter Vervellum sends.")

    /// HTTP 401 or 403. Named because a backend may recognise it and say something more
    /// useful: a SearXNG instance answers 403 when JSON results are simply not enabled,
    /// which has nothing to do with a key.
    static func rejectedCredential(_ code: Int) -> ResearchError {
        ResearchError("The provider rejected the API key (HTTP \(code)). Check the key in "
                      + "the provider settings.")
    }

    static func providerStatus(_ code: Int) -> ResearchError {
        ResearchError("The provider returned HTTP \(code). Check the endpoint, key, model and quota.")
    }
}
