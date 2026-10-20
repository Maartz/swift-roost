import Testing
@testable import Roost

private struct CommandApp: RoostApp {
    // Nothing listens on port 1, so a command that connects fails with status 1.
    let database: Database? = Database(hostname: "127.0.0.1", port: 1, username: "postgres", password: "", database: "command_app")

    @RouteBuilder var routes: [Route] {
        GET("/") { $0 }
        POST("/todos") { $0 }
        scope("/api") {
            DELETE("/todos/:id") { $0 }
        }
    }
}

private struct DatabaseFreeApp: RoostApp {
    @RouteBuilder var routes: [Route] { GET("/") { $0 } }
}

@Suite("App commands")
struct AppCommandTests {
    @Test("db rejects unknown commands before connecting")
    func databaseUsage() async {
        for arguments in [[], ["migrate"], ["create", "extra"]] {
            #expect(await CommandApp().runDatabaseCommand(arguments) == 64, "\(arguments)")
        }
    }

    @Test("db needs a configured database")
    func databaseRequired() async {
        #expect(await DatabaseFreeApp().runDatabaseCommand(["create"]) == 1)
    }

    @Test("drop and reset refuse production before connecting", arguments: ["drop", "reset"])
    func productionDrop(command: String) async {
        let status = await Roost.$environmentOverride.withValue(.prod) {
            await CommandApp().runDatabaseCommand([command])
        }
        #expect(status == 77)
    }

    @Test("a connection failure is reported, not thrown")
    func connectionFailure() async {
        #expect(await CommandApp().runDatabaseCommand(["create"]) == 1)
    }

    @Test("routes lists method and full path in matching order")
    func routeTable() {
        #expect(CommandApp().roost_routeTable == """
            GET     /
            POST    /todos
            DELETE  /api/todos/:id
            """)
    }
}
