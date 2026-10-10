import Foundation
import Logging

// MARK: - Email

/// Represents a single email message.
public struct Email: Sendable {
    /// Recipient email address.
    public let to: String
    /// Sender email address.
    public let from: String
    /// Email subject line.
    public let subject: String
    /// Body content (plain text or HTML depending on `isHTML`).
    public let body: String
    /// Whether the body is HTML content.
    public let isHTML: Bool

    public init(
        to: String,
        from: String,
        subject: String,
        body: String,
        isHTML: Bool = false
    ) {
        self.to = to
        self.from = from
        self.subject = subject
        self.body = body
        self.isHTML = isHTML
    }
}

// MARK: - MailDelivery Protocol

/// Protocol for email delivery backends.
public protocol MailDelivery: Sendable {
    /// Delivers an email through the configured backend.
    func deliver(_ email: Email) async throws
}

// MARK: - LoggerDelivery

/// Development email backend that logs email details instead of sending.
public struct LoggerDelivery: MailDelivery {
    private let label: String

    /// Creates a logger-based delivery backend.
    /// - Parameter label: Logger label. Defaults to "roost.mailer".
    public init(label: String = "roost.mailer") {
        self.label = label
    }

    public func deliver(_ email: Email) async throws {
        let logger = Logger(label: label)
        logger.info(
            "Email (dev mode — not sent)",
            metadata: [
                "to": .string(email.to),
                "from": .string(email.from),
                "subject": .string(email.subject),
                "isHTML": .string(String(email.isHTML)),
            ]
        )
    }
}

// MARK: - TestDelivery

/// Test email backend that collects sent emails for assertions.
public actor TestDelivery: MailDelivery {
    /// All emails that have been delivered through this backend.
    public private(set) var sentEmails: [Email] = []

    public init() {}

    public func deliver(_ email: Email) async throws {
        sentEmails.append(email)
    }

    /// Clears all collected emails for test isolation.
    public func reset() {
        sentEmails = []
    }
}

// MARK: - SMTPDelivery (Stub)

/// Placeholder SMTP delivery backend. Requires `swift-nio-smtp` or similar for production use.
@available(*, deprecated, message: "SMTPDelivery doesn't send mail: it logs a warning. Implement MailDelivery with an SMTP or API client. Roost 3.0 removes it from the stable API until it is implemented.")
public struct SMTPDelivery: MailDelivery {
    private let host: String
    private let port: Int
    private let username: String
    private let password: String
    private let useTLS: Bool

    /// Creates an SMTP delivery backend.
    ///
    /// > Note: This is a stub implementation. Production SMTP requires a library
    ///   like `swift-nio-smtp`. Configure credentials and a real mailer library
    ///   before using in production.
    public init(
        host: String,
        port: Int = 587,
        username: String,
        password: String,
        useTLS: Bool = true
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.useTLS = useTLS
    }

    public func deliver(_ email: Email) async throws {
        let logger = Logger(label: "roost.mailer")
        logger.warning(
            "SMTP delivery is a stub — configure a real SMTP library like swift-nio-smtp to send emails",
            metadata: [
                "to": .string(email.to),
                "subject": .string(email.subject),
                "host": .string(host),
            ]
        )
    }
}

// MARK: - Mailer Facade

/// Global mailer facade. Configured with a ``MailDelivery`` backend and accessed
/// throughout the application to send emails.
///
/// ```swift
/// // Configure at startup (e.g., in willStart)
/// Mailer.delivery = LoggerDelivery()
///
/// // Send an email from anywhere
/// try await Mailer.deliver(Email(
///     to: "user@example.com",
///     from: "noreply@app.com",
///     subject: "Welcome!",
///     body: "Thanks for signing up."
/// ))
/// ```
public enum Mailer {
    private nonisolated(unsafe) static var _delivery: (any MailDelivery)?

    /// The active email delivery backend.
    ///
    /// Must be set before sending any emails. Defaults to `LoggerDelivery()`
    /// on first access in debug/test environments.
    public static var delivery: any MailDelivery {
        get {
            if _delivery == nil {
                _delivery = LoggerDelivery()
            }
            return _delivery!
        }
        set {
            _delivery = newValue
        }
    }

    /// Sends an email through the configured delivery backend.
    /// - Parameter email: The email to send.
    public static func deliver(_ email: Email) async throws {
        try await delivery.deliver(email)
    }
}
