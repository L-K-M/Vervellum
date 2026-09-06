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

    static func providerStatus(_ code: Int) -> ResearchError {
        ResearchError("The provider returned HTTP \(code). Check the endpoint, key, model and quota.")
    }
}
