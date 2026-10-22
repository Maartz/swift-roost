# Getting started

Generate a small app, run its first route, and test it without a database.

## Overview

This guide uses Roost 2.5.0 with published ESW 1.7.0,
Spectro 2.x (from 2.3.1), and Nexus 2.x (from 2.1.0). You need Swift 6.3 or later and macOS 15+ or a
supported Linux environment. On Debian/Ubuntu, Nexus also needs `zlib1g-dev`
at build time and `zlib1g` at runtime.

Generated apps resolve released packages directly. No companion source
checkouts or dependency overrides are required.

### Install the CLI

Install the CLI with [Mint](https://github.com/yonaskolb/Mint):

```sh
brew install mint
mint install roost-framework/roost-cli@3.0.1
roost --version
```

Mint builds the CLI from source and links `roost` into `~/.mint/bin`; add that
directory to your `PATH`. Leave `ROOST_FRAMEWORK_PATH`,
`ROOST_ECOSYSTEM_PATH`, and `ROOST_ESW_PATH` unset to select published versions
of Roost and its companion packages.

Without Mint, for example on Linux, build from a checkout:

```sh
git clone --branch 3.0.1 --depth 1 https://github.com/roost-framework/roost-cli.git
cd roost-cli
swift build -c release --product roost
```

Then copy `.build/release/roost` to a directory on your `PATH`.

### Create an application

Create the app:

```sh
roost new HelloApp --no-db --no-esw
cd HelloApp
roost server --port 8080
```

Open [localhost:8080](http://localhost:8080). The generated app returns a JSON
welcome message. This starter needs no PostgreSQL server or templates.

The development server watches Swift and template files. A successful build
restarts the app. A failed build prints diagnostics and leaves the previous
server available. Open HTML pages reload after a successful restart, and
stylesheet changes in `Public/` apply without a reload; refresh other responses,
such as this JSON, yourself. Page state is not preserved across a restart. See
<doc:RoutingAndMiddleware#Reload-the-browser-during-development>.

### Write a controller

The generated app routes `/` to the `home` action of `PageController`. Replace
`Sources/HelloApp/Controllers/PageController.swift` with a controller that has
a second action:

```swift
import Roost

struct PageController: Controller {
    enum Action: String, ControllerAction {
        case home, hello
    }

    static func action(_ action: Action) -> Plug {
        switch action {
        case .home: home
        case .hello: hello
        }
    }

    static func home(_ conn: Connection) async throws -> Connection {
        conn.text("Hello, Roost.")
    }

    static func hello(_ conn: Connection) async throws -> Connection {
        try conn.json(value: [
            "hello": conn.params["name"] ?? "world"
        ])
    }
}
```

Then replace `Sources/HelloApp/App.swift` with this complete application:

```swift
import Roost

@main
struct HelloApp: RoostApp {
    @RouteBuilder var routes: [Route] {
        GET("/", PageController.self, .home)
        GET("/hello/:name", PageController.self, .hello)
    }
}
```

Only the routes are required here. The default application has no database or
sessions and binds to `127.0.0.1:8080`. Its default middleware logs each request
with the action that handled it, such as `GET /hello/ada → PageController.hello`.
The compiler checks that every route names an action the controller declares,
and that every action has a function. See <doc:Controllers>.

### Test the application

Stop the server with Ctrl-C, then replace the generated welcome test in
`Tests/HelloAppTests/AppTests.swift` to match the new response:

```swift
import Testing
import RoostTest
@testable import HelloApp

@Test func homeResponds() async throws {
    let app = try await TestApp(HelloApp.self, database: .some(nil))
    let response = try await app.get("/")
    #expect(response.status == .ok)
    #expect(response.text == "Hello, Roost.")
    await app.shutdown()
}
```

Run `swift test`. `TestApp` exercises the application's middleware and routes
in-process; it does not bind a network port.

### Choose the next step

- Add controllers, resources, and permitted parameters with <doc:Controllers>.
- Add middleware and route groups with <doc:RoutingAndMiddleware>.
- Add compiled HTML and request-aware forms with <doc:ViewsAndForms>.
- Generate an authenticated app with <doc:CLIAndGenerators>.
- Try [the browser playground](https://roost-framework.github.io/swift-roost/playground.html)
  for a guided preview without installing Swift. That preview simulates its
  supported examples in JavaScript; it does not execute arbitrary Swift.
