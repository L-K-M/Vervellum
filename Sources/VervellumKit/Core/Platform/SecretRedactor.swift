import Foundation

/// Strips things that look like credentials out of text before it leaves the Mac.
///
/// This exists because of one feature: **research the selection**. A user who presses
/// that shortcut with a terminal window focused can select — and therefore transmit —
/// an API key, a `.env` line, a private key block, or a connection string, without
/// ever reading what they sent. The same hazard applies to anything pasted into the
/// composer in a hurry.
///
/// Two things it is honest about:
///
/// * **It is a safety net, not a guarantee.** A secret with no recognisable shape (a
///   plain dictionary-word password, a customer name) will pass straight through.
///   Redaction reduces accidental disclosure; it does not make the composer safe for
///   deliberate secrets.
/// * **It errs toward redacting.** A false positive costs the user a re-typed word. A
///   false negative sends a live credential to a third party. Where the two conflict,
///   the pattern is written to fire.
///
/// Pure and dependency-free, so it is fully unit-testable.
enum SecretRedactor {

    /// What replaces a match. Deliberately conspicuous — a user scanning the composer
    /// before pressing Return should see immediately that something was removed.
    static let placeholder = "[redacted]"

    /// Patterns matched in order. Each is anchored enough that ordinary prose does not
    /// trip it, and each carries the reason it is here.
    private static let patterns: [(name: String, expression: NSRegularExpression)] = {
        let sources: [(String, String)] = [
            // A PEM block: unambiguous, and the highest-severity thing that can appear
            // in a selection. Matched first so its base64 body is never re-matched.
            ("pem", #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#),
            // Authorization headers, copied wholesale out of curl commands and logs.
            // Outside an `Authorization:` header the value must contain a digit or a
            // punctuation mark: every real token does and no English word does, so "a
            // basic misunderstanding" and "token internationalization" are left alone.
            ("bearer",
             #"(?i)(?:\bauthorization\s*:\s*(?:bearer|basic|token)?\s*[A-Za-z0-9._~+/=-]{16,}"#
                 + #"|\b(?:bearer|basic|token)\s+(?=[A-Za-z0-9._~+/=-]{16,})[A-Za-z-]*[0-9._~+/=][A-Za-z0-9._~+/=-]*)"#),
            // `KEY=value` / `password: value` from .env files, YAML and config dumps.
            // The value's character class deliberately excludes brackets and spaces:
            // without that, `let token = parser.next()` reads as a leaked token.
            // Real config keys wrap the keyword on both sides — DATABASE_TOKEN,
            // STRIPE_SECRET_KEY, GH_ACCESS_TOKEN_V2 — and `_` is a word character, so a
            // bare `\b` on either side of the keyword would miss every one of them.
            // Hence the optional prefix and suffix groups.
            ("assignment",
             #"(?i)\b(?:[A-Za-z0-9]+[_-]){0,3}(?:api[_-]?key|secret|token|password|passwd|pwd|access[_-]?key|private[_-]?key|client[_-]?secret)(?:[_-][A-Za-z0-9]+){0,2}\b\s*[:=]\s*["']?[A-Za-z0-9._~+/=-]{12,}["']?"#),
            // Vendor-prefixed keys, which are self-identifying by design. Stripe's use an
            // underscore and name the mode — sk_live_, rk_test_ — and a bare one copied
            // out of a dashboard or a terminal has no `=` or `Bearer` for the other
            // patterns to anchor on.
            ("vendor", #"\b(?:sk|pk|rk)-[A-Za-z0-9_-]{16,}|\b(?:sk|pk|rk)_(?:live|test)_[A-Za-z0-9]{16,}"#),
            ("github", #"\bgh[pousr]_[A-Za-z0-9]{20,}"#),
            ("slack", #"\bxox[abposr]-[A-Za-z0-9-]{10,}"#),
            ("google", #"\bAIza[A-Za-z0-9_-]{30,}"#),
            ("aws", #"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"#),
            // A credential embedded in a URL. Also blocked at the endpoint level, but
            // this catches one pasted as context.
            ("urlUserInfo", #"\b[a-z][a-z0-9+.-]*://[^\s/@:]+:[^\s/@]+@"#),
            // A JSON Web Token: three base64url segments.
            ("jwt", #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#),
        ]
        return sources.compactMap { name, pattern in
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (name, expression)
        }
    }()

    /// The result of a redaction pass.
    struct Result: Equatable {
        var text: String
        /// How many spans were replaced. Zero means the text is unchanged.
        var redactionCount: Int

        var didRedact: Bool { redactionCount > 0 }
    }

    /// Redacts `text`, returning it with a count of what was removed.
    static func redact(_ text: String) -> Result {
        var current = text
        var count = 0
        for (_, expression) in patterns {
            let range = NSRange(current.startIndex..<current.endIndex, in: current)
            let matches = expression.numberOfMatches(in: current, range: range)
            guard matches > 0 else { continue }
            count += matches
            current = expression.stringByReplacingMatches(in: current, range: range,
                                                          withTemplate: placeholder)
        }
        return Result(text: current, redactionCount: count)
    }
}
