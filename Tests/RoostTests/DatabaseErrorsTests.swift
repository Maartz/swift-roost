import NIOCore
import PostgresNIO
import Roost
import Testing

/// A server error as PostgresNIO's connection API throws it inside Spectro's transactions. Its message
/// has no public initializer, so it's read from the wire format: a code byte, then a null-terminated
/// string, for each field.
private func serverError(sqlState: String) throws -> PostgresError {
    var buffer = ByteBuffer()
    buffer.writeInteger(PostgresMessage.Error.Field.sqlState.rawValue)
    buffer.writeNullTerminatedString(sqlState)
    buffer.writeInteger(PostgresMessage.Error.Field.message.rawValue)
    buffer.writeNullTerminatedString("duplicate key value violates unique constraint \"users_email_key\"")
    return .server(try parsed(PostgresMessage.Error.self, from: &buffer))
}

/// `parse(from:)` is deprecated with the protocol it belongs to, and is the only public way to make a
/// message. Calling it through this protocol keeps the deprecation warning out of the build.
private protocol WireMessage {
    static func parse(from buffer: inout ByteBuffer) throws -> Self
}

extension PostgresMessage.Error: WireMessage {}

private func parsed<Message: WireMessage>(_: Message.Type, from buffer: inout ByteBuffer) throws -> Message {
    try Message.parse(from: &buffer)
}

@Suite("Database errors")
struct DatabaseErrorsTests {
    @Test("a unique violation is recognized as PostgresNIO's PostgresError, and through Spectro's wrappers")
    func postgresError() throws {
        let violation = try serverError(sqlState: "23505")
        let query = SpectroError.queryExecutionFailed(sql: "INSERT INTO users …", error: violation)
        #expect(isUniqueConstraintViolation(violation))
        #expect(isUniqueConstraintViolation(query))
        #expect(isUniqueConstraintViolation(SpectroError.transactionFailed(underlying: query)))
        #expect(isUniqueConstraintViolation(
            SpectroError.transactionAndRollbackFailed(original: query, rollback: PostgresError.connectionClosed)
        ))
    }

    @Test("other errors aren't unique violations")
    func otherErrors() throws {
        let foreignKey = try serverError(sqlState: "23503")
        #expect(!isUniqueConstraintViolation(foreignKey))
        #expect(!isUniqueConstraintViolation(SpectroError.transactionFailed(underlying: foreignKey)))
        #expect(!isUniqueConstraintViolation(PostgresError.connectionClosed))
        #expect(!isUniqueConstraintViolation(SpectroError.transactionDeadlock))
        #expect(!isUniqueConstraintViolation(ValidationErrors()))
    }
}
