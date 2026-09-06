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
    static let invalidResponse = ResearchError(
        "The provider returned a response Vervellum could not read.")
    static let cancelled = ResearchError("Research cancelled.")
    static let streamInterrupted = ResearchError(
        "The model's provider reported an error part-way through the answer. Try again.")

    static func providerStatus(_ code: Int) -> ResearchError {
        ResearchError("The provider returned HTTP \(code). Check the endpoint, key, model and quota.")
    }
}
