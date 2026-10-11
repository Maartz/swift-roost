import Spectro
import PostgresNIO

/// Inspect PostgreSQL's structured SQLSTATE, including errors wrapped by Spectro.
/// Use alongside a database unique constraint; a preflight lookup alone can race.
///
/// PostgresNIO reports a server error as `PSQLError`, or as its older
/// `PostgresError` from the connection's query API, which Spectro's queries
/// use inside a transaction. Either may arrive wrapped in Spectro's
/// `queryExecutionFailed` and `transactionFailed`.
public func isUniqueConstraintViolation(_ error: any Error) -> Bool {
    if let postgres = error as? PSQLError {
        return postgres.serverInfo?[.sqlState] == "23505"
    }
    if let postgres = error as? PostgresError {
        return postgres.code == .uniqueViolation
    }
    guard let error = error as? SpectroError else { return false }
    switch error {
    case .queryExecutionFailed(_, let underlying), .transactionFailed(let underlying):
        return isUniqueConstraintViolation(underlying)
    case .transactionAndRollbackFailed(let original, _):
        return isUniqueConstraintViolation(original)
    default:
        return false
    }
}
