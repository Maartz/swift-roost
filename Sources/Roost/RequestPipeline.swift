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
    if let sessions = app.sessionStore {
        plugs.append(session(store: (sessions as? KeyValueSessionStore)?.using(store) ?? sessions))
    }
    plugs += app.plugs
    plugs.append { conn in try await router(conn) }
    return roost_liveReload(roost_requestPipeline(plugs, customErrorPage: app.customErrorPage))
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
