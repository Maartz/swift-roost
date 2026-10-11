import Foundation
import HTTPTypes
import InMemoryTracing
import Logging
import Nexus
import NexusRouter
import Testing
import Tracing

@testable import Roost
@testable import RoostTest

// MARK: - Fixtures

/// Appends `name` to the `trail` assign so tests can see which plugs ran.
private func stamp(_ name: String) -> Plug {
    { conn in conn.assign(key: "trail", value: (conn.assigns["trail"] as? String ?? "") + name) }
}

private let requireAdmin: Plug = { conn in
    guard conn.request.headerFields[HTTPField.Name("X-Admin")!] == "yes" else {
        return conn.respond(status: .forbidden)
    }
    return conn
}

private func reply(_ conn: Connection, _ action: String) -> Connection {
    let route = conn.matchedRoute
    let id = conn.params["id"].map { " id=\($0)" } ?? ""
    let trail = conn.assigns["trail"] as? String ?? ""
    return conn.text("\(action)\(id) [\(trail)] \(route.controller ?? "-").\(route.action ?? "-") \(route.pattern ?? "-")")
}

private struct RecipeParams: Codable, Sendable, Equatable {
    let title: String
    let servings: Int
    let vegetarian: Bool
    let notes: String?
}

private struct RecipeController: Controller {
    enum Action: String, ControllerAction {
        case index, new, create, show, edit, update, delete, publish
    }

    static let plugs: [ActionPlug<Action>] = [
        .plug(stamp("all ")),
        .plug(stamp("loaded "), only: [.show, .edit, .update, .delete]),
        .plug(requireAdmin, only: [.publish]),
        .plug(stamp("not-index "), except: [.index]),
    ]

    static func action(_ action: Action) -> Plug {
        switch action {
        case .index: index
        case .new: new
        case .create: create
        case .show: show
        case .edit: edit
        case .update: update
        case .delete: delete
        case .publish: publish
        }
    }

    static func index(_ conn: Connection) async throws -> Connection { reply(conn, "index") }
    static func new(_ conn: Connection) async throws -> Connection { reply(conn, "new") }
    static func show(_ conn: Connection) async throws -> Connection { reply(conn, "show") }
    static func edit(_ conn: Connection) async throws -> Connection { reply(conn, "edit") }
    static func update(_ conn: Connection) async throws -> Connection { reply(conn, "update") }
    static func delete(_ conn: Connection) async throws -> Connection { reply(conn, "delete") }
    static func publish(_ conn: Connection) async throws -> Connection { reply(conn, "publish") }

    static func create(_ conn: Connection) async throws -> Connection {
        do {
            return try conn.json(value: conn.permit(RecipeParams.self))
        } catch let errors as ValidationErrors {
            return try conn.json(status: .unprocessableContent, value: errors)
        }
    }
}

/// Declares only two REST actions, so `resources` routes only those.
private struct ArticleController: Controller {
    enum Action: String, ControllerAction { case index, show }

    static func action(_ action: Action) -> Plug {
        switch action {
        case .index: { conn in reply(conn, "index") }
        case .show: { conn in reply(conn, "show") }
        }
    }
}

private struct OrderParams: Codable, Sendable {
    let id: Int
    let note: String
}

private struct ProbeController: Controller {
    enum Action: String, ControllerAction { case explode, order }

    static func action(_ action: Action) -> Plug {
        switch action {
        case .explode: { _ in throw CocoaError(.fileNoSuchFile) }
        case .order: { conn in try conn.json(value: ["id": conn.permit(OrderParams.self).id]) }
        }
    }
}

private struct ControllerApp: RoostApp {
    var plugs: [Plug] { [bodyParser()] }

    @RouteBuilder var routes: [Route] {
        resources("/recipes", RecipeController.self)
        POST("/recipes/:id/publish", RecipeController.self, .publish)
        resources("/drafts", RecipeController.self, only: [.index, .new])
        resources("/archive", RecipeController.self, except: [.create, .update, .delete])
        resources("/articles", ArticleController.self)
        scope("/api") {
            GET("/boom", ProbeController.self, .explode)
            PUT("/orders/:id", ProbeController.self, .order)
        }
    }
}

// MARK: - Routing

@Suite("Controllers")
struct ControllerTests {
    @Test("resources maps each REST action to its verb and path", arguments: [
        (HTTPRequest.Method.get, "/recipes", "index"),
        (.get, "/recipes/new", "new"),
        (.get, "/recipes/42", "show id=42"),
        (.get, "/recipes/42/edit", "edit id=42"),
        (.patch, "/recipes/42", "update id=42"),
        (.put, "/recipes/42", "update id=42"),
        (.delete, "/recipes/42", "delete id=42"),
    ])
    func restRoutes(method: HTTPRequest.Method, path: String, expected: String) async throws {
        let app = try await TestApp(ControllerApp.self)
        let response = try await app.request(method: method, path: path)
        #expect(response.status == .ok)
        #expect(response.text.hasPrefix(expected + " "))
    }

    @Test("routing records the controller, action, and route pattern")
    func matchedRoute() async throws {
        let app = try await TestApp(ControllerApp.self)
        let response = try await app.get("/recipes/42")
        #expect(response.text.hasSuffix("RecipeController.show /recipes/:id"))
    }

    @Test("only:, except:, and the controller's own actions limit what is routed")
    func narrowedResources() async throws {
        let app = try await TestApp(ControllerApp.self)
        #expect(try await app.get("/drafts/new").text.hasPrefix("new "))
        #expect(try await app.get("/drafts/1").status == .notFound)
        #expect(try await app.post("/drafts", json: ["title": "x"]).status == .methodNotAllowed)
        #expect(try await app.get("/archive/1/edit").text.hasPrefix("edit id=1 "))
        #expect(try await app.delete("/archive/1").status == .methodNotAllowed)
        #expect(try await app.get("/articles/7").text.hasPrefix("show id=7 "))
        #expect(try await app.get("/articles/new").text.hasPrefix("show id=new "))
        #expect(try await app.post("/articles", json: ["title": "x"]).status == .methodNotAllowed)
    }

    @Test("controller plugs run in order, limited by only: and except:")
    func controllerPlugs() async throws {
        let app = try await TestApp(ControllerApp.self)
        #expect(try await app.get("/recipes").text.contains("[all ]"))
        #expect(try await app.get("/recipes/1").text.contains("[all loaded not-index ]"))
        #expect(try await app.get("/recipes/new").text.contains("[all not-index ]"))
    }

    @Test("a controller plug that halts stops the action")
    func haltingPlug() async throws {
        let app = try await TestApp(ControllerApp.self)
        #expect(try await app.request(method: .post, path: "/recipes/1/publish").status == .forbidden)
        let allowed = try await app.request(method: .post, path: "/recipes/1/publish", headers: ["X-Admin": "yes"])
        #expect(allowed.text.hasPrefix("publish id=1 "))
    }

    @Test("resources rejects only: with an action that is not REST")
    func nonRESTAction() async {
        await #expect(processExitsWith: .failure) {
            _ = resources("/recipes", RecipeController.self, only: [.publish])
        }
    }

    @Test("resources rejects only: combined with except:")
    func onlyAndExcept() async {
        await #expect(processExitsWith: .failure) {
            _ = resources("/recipes", RecipeController.self, only: [.index], except: [.show])
        }
    }
}

// MARK: - Params

@Suite("Permitted params")
struct PermittedParamsTests {
    @Test("form fields are converted to the declared types and undeclared fields are dropped")
    func form() async throws {
        let app = try await TestApp(ControllerApp.self)
        let response = try await app.post("/recipes", form: [
            "title": "Pie", "servings": "4", "notes": "", "userId": "someone-else", "admin": "true",
        ])
        #expect(response.status == .ok)
        let params = try response.decode(as: RecipeParams.self)
        #expect(params == RecipeParams(title: "Pie", servings: 4, vegetarian: false, notes: nil))
        #expect(!response.text.contains("someone-else"))
    }

    @Test("an invalid or missing form field is a validation error naming the field")
    func formErrors() async throws {
        let app = try await TestApp(ControllerApp.self)
        let invalid = try await app.post("/recipes", form: ["title": "Pie", "servings": "many"])
        #expect(invalid.status == .unprocessableContent)
        #expect(try invalid.decode(as: ValidationErrors.self)["servings"] == ["is invalid"])
        let missing = try await app.post("/recipes", form: ["servings": "2"])
        #expect(try missing.decode(as: ValidationErrors.self)["title"] == ["can't be blank"])
    }

    @Test("path parameters take precedence over form fields")
    func pathWins() async throws {
        let app = try await TestApp(ControllerApp.self)
        let response = try await app.request(
            method: .put, path: "/api/orders/7", body: Data("id=99&note=hi".utf8),
            headers: ["Content-Type": "application/x-www-form-urlencoded"])
        #expect(response.json["id"] as? Int == 7)
    }

    @Test("JSON bodies decode with the same permitted fields")
    func json() async throws {
        let app = try await TestApp(ControllerApp.self)
        let body: [String: JSONFixture] = [
            "title": .string("Soup"), "servings": .int(2), "vegetarian": .bool(true), "admin": .bool(true),
        ]
        let response = try await app.post("/recipes", json: body)
        #expect(try response.decode(as: RecipeParams.self) == RecipeParams(title: "Soup", servings: 2, vegetarian: true, notes: nil))
    }

    @Test("JSON errors name the field; a malformed body is a bad request")
    func jsonErrors() async throws {
        let app = try await TestApp(ControllerApp.self)
        let missing = try await app.post("/recipes", json: ["title": "Soup"])
        #expect(try missing.decode(as: ValidationErrors.self)["servings"] == ["can't be blank"])
        let wrongType: [String: JSONFixture] = ["title": .int(5), "servings": .int(1), "vegetarian": .bool(false)]
        let invalid = try await app.post("/recipes", json: wrongType)
        #expect(try invalid.decode(as: ValidationErrors.self)["title"] == ["is invalid"])
        let malformed = try await app.request(method: .post, path: "/recipes", body: Data("{".utf8),
                                              headers: ["Content-Type": "application/json"])
        #expect(malformed.status == .badRequest)
    }

    @Test("isJSONRequest is true for JSON and JSON-based content types only", arguments: [
        ("application/json", true),
        ("application/json; charset=utf-8", true),
        ("application/vnd.api+json", true),
        ("application/x-www-form-urlencoded", false),
        (nil, false),
    ] as [(String?, Bool)])
    func jsonRequest(contentType: String?, expected: Bool) {
        var fields = HTTPFields()
        if let contentType { fields[.contentType] = contentType }
        let request = HTTPRequest(method: .post, scheme: "http", authority: "localhost", path: "/recipes",
                                  headerFields: fields)
        #expect(Connection(request: request).isJSONRequest == expected)
    }
}

/// Mixed-type JSON values for request bodies.
private enum JSONFixture: Encodable, Sendable {
    case string(String), int(Int), bool(Bool), object([String: JSONFixture])

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

// MARK: - Request logging

private final class LogCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(message: String, metadata: Logger.Metadata)] = []

    func append(_ message: String, _ metadata: Logger.Metadata) {
        lock.withLock { entries.append((message, metadata)) }
    }

    func take() -> [(message: String, metadata: Logger.Metadata)] {
        lock.withLock { defer { entries = [] }; return entries }
    }
}

private struct CaptureHandler: LogHandler {
    let capture: LogCapture
    var logLevel: Logger.Level = .trace
    var metadata: Logger.Metadata = [:]

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?,
             source: String, file: String, function: String, line: UInt) {
        capture.append(message.description, metadata ?? [:])
    }
}

private let logs = LogCapture()

private struct LoggedApp: RoostApp {
    var plugs: [Plug] {
        [
            requestId(generator: { "req-1" }),
            roost_requestLogger(filterParameters: ["email"], logger: Logger(label: "test") { _ in CaptureHandler(capture: logs) }),
            bodyParser(),
        ]
    }

    @RouteBuilder var routes: [Route] {
        resources("/recipes", RecipeController.self)
        GET("/boom", ProbeController.self, .explode)
        GET("/health") { conn in conn.text("ok") }
    }
}

private struct OverrideApp: RoostApp {
    var plugs: [Plug] {
        [roost_requestLogger(logger: Logger(label: "test") { _ in CaptureHandler(capture: logs) }), bodyParser(), methodOverride()]
    }

    @RouteBuilder var routes: [Route] {
        resources("/recipes", RecipeController.self)
    }
}

@Suite("Request logging", .serialized)
struct RequestLoggerTests {
    @Test("one line names the action, route, and parameters, with secrets filtered")
    func actionLine() async throws {
        _ = logs.take()
        let app = try await TestApp(LoggedApp.self)
        _ = try await app.post("/recipes", form: [
            "title": "Pie", "servings": "2", "password": "hunter2", "_csrf_token": "abc", "email": "a@b.test",
        ])
        let entries = logs.take()
        let entry = try #require(entries.first)
        #expect(entries.count == 1)
        #expect(entry.message.hasPrefix("POST /recipes → RecipeController.create → 200 in "))
        #expect(entry.metadata["controller"] == "RecipeController")
        #expect(entry.metadata["action"] == "create")
        #expect(entry.metadata["route"] == "/recipes")
        #expect(entry.metadata["request_id"] == "req-1")
        #expect(entry.metadata["status"] == "200")
        guard case .dictionary(let params)? = entry.metadata["params"] else {
            Issue.record("Missing params metadata")
            return
        }
        #expect(params["title"] == "Pie")
        #expect(params["password"] == "[FILTERED]")
        #expect(params["_csrf_token"] == "[FILTERED]")
        #expect(params["email"] == "[FILTERED]")
    }

    @Test("secrets nested in JSON bodies are filtered")
    func nestedJSON() async throws {
        _ = logs.take()
        let app = try await TestApp(LoggedApp.self)
        let body: [String: JSONFixture] = [
            "title": .string("Pie"), "servings": .int(1), "vegetarian": .bool(false),
            "card": .object(["number": .string("4242"), "cvv": .string("123")]),
        ]
        _ = try await app.post("/recipes", json: body)
        let entry = try #require(logs.take().first)
        guard case .dictionary(let params)? = entry.metadata["params"] else {
            Issue.record("Missing params metadata")
            return
        }
        #expect(params["card"] == #"{"cvv":"[FILTERED]","number":"4242"}"#)
        #expect(params["vegetarian"] == "false")
        #expect(params["servings"] == "1")
    }

    @Test("a form's _method override is logged as the method that was routed")
    func methodOverride() async throws {
        _ = logs.take()
        let app = try await TestApp(OverrideApp.self)
        _ = try await app.post("/recipes/3", form: ["_method": "DELETE"])
        let entry = try #require(logs.take().first)
        #expect(entry.message.hasPrefix("DELETE /recipes/3 → RecipeController.delete → 200 in "))
    }

    @Test("an action that throws is still logged by name")
    func errorResponse() async throws {
        _ = logs.take()
        let app = try await TestApp(LoggedApp.self)
        #expect(try await app.get("/boom").status == .internalServerError)
        let entry = try #require(logs.take().first)
        #expect(entry.message.hasPrefix("GET /boom → ProbeController.explode → 500 in "))
    }

    @Test("closure routes log their pattern, and the query string is logged as params")
    func closureRoute() async throws {
        _ = logs.take()
        let app = try await TestApp(LoggedApp.self)
        _ = try await app.get("/health?verbose=1")
        let entry = try #require(logs.take().first)
        #expect(entry.message.hasPrefix("GET /health → 200 in "))
        #expect(entry.metadata["route"] == "/health")
        #expect(entry.metadata["controller"] == nil)
        #expect(entry.metadata["params"] == .dictionary(["verbose": "1"]))
    }
}

// MARK: - Tracing

private let tracer = InMemoryTracer()

private struct TracedApp: RoostApp {
    var plugs: [Plug] { [requestId(generator: { "req-7" }), tracing(tracer: tracer)] }

    @RouteBuilder var routes: [Route] {
        resources("/recipes", RecipeController.self)
        GET("/boom", ProbeController.self, .explode)
    }
}

@Suite("Action tracing", .serialized)
struct ActionTracingTests {
    @Test("the server span is named after the route, with a child span for the action")
    func spans() async throws {
        tracer.clearAll()
        let app = try await TestApp(TracedApp.self)
        let response = try await app.get("/recipes/42")
        #expect(response.header("X-Request-ID") == "req-7")

        let spans = tracer.popFinishedSpans()
        let server = try #require(spans.first { $0.kind == .server })
        let action = try #require(spans.first { $0.kind == .internal })
        #expect(server.operationName == "GET /recipes/:id")
        #expect(server.attributes.get("http.route") == SpanAttribute.string("/recipes/:id"))
        #expect(server.attributes.get("roost.controller") == SpanAttribute.string("RecipeController"))
        #expect(server.attributes.get("roost.action") == SpanAttribute.string("show"))
        #expect(server.attributes.get("roost.request_id") == SpanAttribute.string("req-7"))
        #expect(action.operationName == "RecipeController.show")
        #expect(action.parentSpanID == server.spanID)
        #expect(action.traceID == server.traceID)
    }

    @Test("an incoming trace context is continued")
    func continuesTrace() async throws {
        tracer.clearAll()
        let app = try await TestApp(TracedApp.self)
        _ = try await app.get("/recipes", headers: [
            InMemoryTracer.traceIDKey: "caller-trace", InMemoryTracer.spanIDKey: "caller-span",
        ])
        let server = try #require(tracer.popFinishedSpans().first { $0.kind == .server })
        #expect(server.traceID == "caller-trace")
        #expect(server.parentSpanID == "caller-span")
    }

    @Test("an action that throws marks its span and the server span as errors")
    func errors() async throws {
        tracer.clearAll()
        let app = try await TestApp(TracedApp.self)
        _ = try await app.get("/boom")
        let spans = tracer.popFinishedSpans()
        let action = try #require(spans.first { $0.kind == .internal })
        let server = try #require(spans.first { $0.kind == .server })
        #expect(action.errors.count == 1)
        #expect(action.status?.code == .error)
        #expect(server.status?.code == .error)
        #expect(server.attributes.get("roost.action") == SpanAttribute.string("explode"))
    }
}
