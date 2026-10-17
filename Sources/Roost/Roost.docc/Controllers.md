# Controllers

Group request handlers into controllers, route to their actions by name, and
decode only the parameters each action accepts.

## Overview

A controller is a Swift type whose actions handle requests, like a controller in
Phoenix or Rails. Routes name a controller and an action instead of holding a
closure, so the router reads as a table of the app's endpoints:

```swift
@RouteBuilder var routes: [Route] {
    GET("/", PageController.self, .home)
    resources("/recipes", RecipeController.self)
    POST("/recipes/:id/publish", RecipeController.self, .publish)
}
```

The compiler checks the names. A route can only name an action the controller
declares, and a controller must provide a function for every action it declares.
Each request records the controller and action that handled it, so request logs
and traces name the action.

### Write a controller

Conform a type to ``Controller``. Its `Action` enum lists the actions, and
``Controller/action(_:)`` returns each action's function from an exhaustive
`switch`:

```swift
import Roost

struct RecipeController: Controller {
    enum Action: String, ControllerAction {
        case index, show, new, create, publish
    }

    static func action(_ action: Action) -> Plug {
        switch action {
        case .index: index
        case .show: show
        case .new: new
        case .create: create
        case .publish: publish
        }
    }

    static func index(_ conn: Connection) async throws -> Connection {
        let recipes = try await RecipesContext(repo: conn.repo()).listRecipes()
        return try conn.render(RecipesIndexView(recipes: recipes), title: "Recipes")
    }

    static func show(_ conn: Connection) async throws -> Connection {
        let id: UUID = try conn.requireParam("id")
        let recipe = try await RecipesContext(repo: conn.repo()).getRecipe(id: id)
        return try conn.render(RecipeShowView(recipe: recipe), title: recipe.title)
    }

    // new, create, and publish follow the same shape.
}
```

An action has the same signature as a plug: it receives the connection and
returns it with a response. Adding a case to `Action` without a matching
`switch` branch fails to compile, and so does a route naming a case that
doesn't exist. The raw value of each case is the action's name in logs and
traces.

### Route actions

``resources(_:_:only:except:)`` routes the REST actions a controller declares:

| Action   | Route                                       |
|----------|---------------------------------------------|
| `index`  | `GET /recipes`                              |
| `new`    | `GET /recipes/new`                          |
| `create` | `POST /recipes`                             |
| `show`   | `GET /recipes/:id`                          |
| `edit`   | `GET /recipes/:id/edit`                     |
| `update` | `PATCH /recipes/:id` and `PUT /recipes/:id` |
| `delete` | `DELETE /recipes/:id`                       |

Actions the controller doesn't declare are not routed. Use `only:` or `except:`
to route fewer of them:

```swift
resources("/recipes", RecipeController.self, only: [.index, .show])
resources("/comments", CommentController.self, except: [.delete])
```

Route any other action with ``GET(_:_:_:)``, ``POST(_:_:_:)``, ``PUT(_:_:_:)``,
``PATCH(_:_:_:)``, or ``DELETE(_:_:_:)``. Naming a non-REST action in `only:`, or
combining `only:` with `except:`, stops the app when its routes are built at
startup.

Routes can still take a closure, which is useful for a health check. Use a
controller for application endpoints so they are logged and traced by action.

### Run plugs before some actions

A controller's ``Controller/plugs`` run after routing and before the action.
Limit a plug to some actions with `only:` or `except:`, like Phoenix's
`plug :authorize when action in [...]`:

```swift
static let plugs: [ActionPlug<Action>] = [
    .plug(requireAuth(), except: [.index, .show]),
    .plug(requireOwner, only: [.publish]),
]
```

Plugs run in the order listed. A plug that halts the connection, such as
`requireAuth()` redirecting to the login page, stops the remaining plugs and
the action.

### Permit parameters

Decode the request's parameters into a `Decodable` type with
``Nexus/Connection/permit(_:decoder:)-(T.Type,_)``. The type is the list of permitted
fields, like Rails' strong parameters or Ecto's `cast`:

```swift
struct RecipeParams: Codable, Sendable {
    let title: String
    let servings: Int
    let vegetarian: Bool
    let notes: String?
}

static func create(_ conn: Connection) async throws -> Connection {
    do {
        let params = try conn.permit(RecipeParams.self)
        let recipe = try await RecipesContext(repo: conn.repo()).createRecipe(params)
        return conn.redirect(to: "/recipes/\(recipe.id)")
    } catch let errors as ValidationErrors {
        return try conn.render(RecipeNewView(values: conn.bodyParams, errors: errors),
                               title: "New recipe", status: .unprocessableContent)
    }
}
```

Fields the type doesn't declare are dropped, so a form can't set `userId` or
`admin` by adding a field. Values are converted to the declared types:

- JSON requests decode the body.
- Other requests decode query, form, and path parameters. A path parameter
  takes precedence over a form field with the same name, and a form field over
  the query.
- Form values follow ``FormValues``: an empty optional field is `nil`, an
  unchecked checkbox is `false`, and dates use ISO 8601.

A missing or invalid field throws ``ValidationErrors`` naming the field, so the
action can render the form again with status 422. A malformed JSON body is a
400 response. Domain rules, such as a minimum length, belong in the context or
a ``Changeset``.

To decode form values outside a request, for example in a test, use
``FormValues/decode(as:)``.

### Permit a model's fields

When the parameters set a model's columns, list them by key path in a
``Permitted`` value instead of declaring a struct.
``Nexus/Connection/permit(_:decoder:)-(Permitted<Model>,_)`` decodes them into
``Changes`` for the model:

```swift
extension Recipe {
    static let editable = Permitted<Recipe>(\.title, \.servings, \.vegetarian, \.notes)
}

static func create(_ conn: Connection) async throws -> Connection {
    do {
        let recipe = try await RecipesContext(repo: conn.repo()).createRecipe(conn.permit(Recipe.editable))
        return conn.redirect(to: "/recipes/\(recipe.id)")
    } catch let errors as ValidationErrors {
        return try conn.render(RecipeNewView(values: conn.bodyParams, errors: errors),
                               title: "New recipe", status: .unprocessableContent)
    }
}
```

Decoding follows the rules above for a struct with the same properties, but
reports every missing or invalid field instead of stopping at the first. See
<doc:DataAndMigrations> to validate the changes and write them.

### Split routers across files

A router is a `[Route]`, so each area of the app can declare its routes in a
`@RouteBuilder` function in its own file, and the app mounts them:

```swift
// Routes/AuthRoutes.swift
@RouteBuilder
func authRoutes() -> [Route] {
    GET("/login", SessionController.self, .new)
    POST("/login", SessionController.self, .create)
    DELETE("/logout", SessionController.self, .delete)
}

// App.swift
@RouteBuilder var routes: [Route] {
    scope("/auth") { authRoutes() }
    resources("/recipes", RecipeController.self)
}
```

Share pipelines between files as `NamedPipeline` values. A misspelled pipeline
is a compile error, and pipelines don't depend on the order files are
evaluated in:

```swift
let browser = NamedPipeline { browserPlugs() }
let authenticated = NamedPipeline { requireAuth() }

@RouteBuilder
func accountRoutes() -> [Route] {
    scope("/account", pipelines: [browser, authenticated]) {
        GET("/", AccountController.self, .show)
    }
}
```

### Log and trace each action

``roost_requestLogger(filterParameters:logger:)`` writes one line per request
once the response is ready, naming the controller action, route, and
parameters:

```text
info roost.request : action=show controller=RecipeController duration_ms=3.1
  params=[id: 42] request_id=4F6C… route=/recipes/:id status=200
  [Roost] GET /recipes/42 → RecipeController.show → 200 in 3.1ms
```

The details are swift-log metadata, so a JSON log handler receives them as
fields. Parameters whose names contain `passw`, `secret`, `token`, `_key`,
`crypt`, `salt`, `certificate`, `otp`, `ssn`, `cvv`, or `cvc` are logged as
`[FILTERED]`, including inside JSON bodies. Add more names with
`filterParameters:`. Requests that fail are logged with their action too.

``tracing(tracer:)`` starts a server span per request. It continues the caller's
trace when the tracer understands the incoming headers, names the span after
the matched route (`GET /recipes/:id`, so one endpoint has one name whatever the
IDs), and wraps each action in a child span named `RecipeController.show`. Spans
your action starts, such as database queries, nest under the action's span.

```swift
var plugs: [Plug] {
    [requestId(), tracing(), roost_requestLogger()] + browserPlugs()
}
```

Logs, spans, and ``metrics()`` read the endpoint from
``Nexus/Connection/matchedRoute``, which you can also read in your own plugs.

## Topics

### Controllers

- ``Controller``
- ``ControllerAction``
- ``ActionPlug``

### Routes

- ``resources(_:_:only:except:)``
- ``GET(_:_:_:)``
- ``POST(_:_:_:)``
- ``PUT(_:_:_:)``
- ``PATCH(_:_:_:)``
- ``DELETE(_:_:_:)``

### Parameters

- ``Nexus/Connection/permit(_:decoder:)-(T.Type,_)``
- ``Nexus/Connection/permit(_:decoder:)-(Permitted<Model>,_)``
- ``Permitted``
- ``FormValues/decode(as:)``
- ``FormValues/decode(_:)``

### Observability

- ``roost_requestLogger(filterParameters:logger:)``
- ``tracing(tracer:)``
- ``MatchedRoute``
