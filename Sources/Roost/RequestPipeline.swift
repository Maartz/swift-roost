import Nexus
import NexusRouter
import Spectro

/// Compose the application identically for HTTP serving and in-process requests.
package func roost_applicationPipeline<App: RoostApp>(
    _ app: App,
    spectro: SpectroClient?,
    repository: (any Repo)? = nil,
    store: any KeyValueStore,
    channels: ChannelRegistry,
    jobs: (any RoostJobQueue)?,
    pubSub: (any RoostPubSub)?
) -> Plug {
    let router = Router { roost_recordingMatches(app.routes) }
    let plugs = roost_routerInputs(
        app, spectro: spectro, repository: repository, store: store, channels: channels, jobs: jobs, pubSub: pubSub
    ) + [{ conn in try await router(conn) }]
    let handle = roost_liveReload(roost_requestPipeline(plugs, customErrorPage: app.customErrorPage))
    // `KeyValueSessionStore()` has no connection, wherever it's installed, so it reads the store from the task.
    return { conn in try await RequestKeyValueStore.$current.withValue(store) { try await handle(conn) } }
}

/// The app's channel socket, or `nil` for an app without channels. An upgrade
/// request runs the app's plugs, as other requests do before the router, then
/// `authenticateSocket(_:)`.
package func roost_channelSockets<App: RoostApp>(
    _ app: App,
    spectro: SpectroClient?,
    store: any KeyValueStore,
    channels: ChannelRegistry,
    jobs: (any RoostJobQueue)?,
    pubSub: (any RoostPubSub)?
) -> ChannelSocketServer? {
    guard !channels.router.routes.isEmpty else { return nil }
    let handle = pipeline(roost_routerInputs(
        app, spectro: spectro, repository: nil, store: store, channels: channels, jobs: jobs, pubSub: pubSub))
    // `RoostApp` isn't `Sendable`, but its requirements read configuration, as `main()` does from every task.
    nonisolated(unsafe) let app: any RoostApp = app
    return ChannelSocketServer(path: channels.router.path + "/websocket", registry: channels) { conn in
        let conn = try await RequestKeyValueStore.$current.withValue(store) { try await handle(conn) }
        guard !conn.isHalted else { throw ChannelError.unauthorized("A plug halted the socket's request") }
        return try await app.authenticateSocket(conn)
    }
}

/// The plugs that run before the router: services, the session, then the app's plugs.
private func roost_routerInputs<App: RoostApp>(
    _ app: App,
    spectro: SpectroClient?,
    repository: (any Repo)?,
    store: any KeyValueStore,
    channels: ChannelRegistry,
    jobs: (any RoostJobQueue)?,
    pubSub: (any RoostPubSub)?
) -> [Plug] {
    let layout = app.layout
    var plugs: [Plug] = [{ conn in
        var result = conn.roost_recordingMatchedRoute()
            .assign(ChannelRegistryKey.self, value: channels)
            .assign(KeyValueStoreKey.self, value: store)
        if let layout { result = result.assign(HTMLLayoutKey.self, value: layout) }
        if let spectro { result = result.assign(SpectroKey.self, value: spectro) }
        if let repository { result = result.assign(RepositoryKey.self, value: repository) }
        if let jobs { result = result.assign(JobQueueKey.self, value: jobs) }
        if let pubSub { result = result.assign(PubSubKey.self, value: pubSub) }
        return result
    }]
    if let sessions = app.sessionStore { plugs.append(session(store: sessions)) }
    return plugs + app.plugs
}

/// The response lifecycle shared by the server and the in-process test harness.
/// Rescue each plug at its input so errors retain state from completed plugs.
/// Session persistence finishes before the adapter runs response hooks.
package func roost_requestPipeline(
    _ plugs: [Plug],
    customErrorPage: ErrorPageRenderer? = nil
) -> Plug {
    let handle = pipeline(plugs.map {
        roost_rescueErrors($0, customErrorPage: customErrorPage)
    })

    return { conn in
        let result = try await handle(conn)
        do {
            try await result.flushSession()
            return result
        } catch {
            return roost_errorResponse(
                error,
                conn: result.suppressSessionCookie(),
                customErrorPage: customErrorPage
            )
        }
    }
}
