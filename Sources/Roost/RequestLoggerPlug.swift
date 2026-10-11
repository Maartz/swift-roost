import Foundation
import Logging
import Nexus

/// Parameter names hidden from request logs, matched case-insensitively as
/// substrings. The list follows Rails' `filter_parameters` defaults, so
/// `password`, `password_confirmation`, `_csrf_token` and `api_key` are hidden.
let roost_filteredParameters = [
    "passw", "secret", "token", "_key", "crypt", "salt", "certificate", "otp", "ssn", "cvv", "cvc",
]

/// Logs one line per request when the response is ready, naming the
/// controller action and its parameters, like Phoenix's request logs:
///
/// ```text
/// info roost.request : action=show controller=RecipeController duration_ms=3.1
///   params=[id: 42] request_id=... route=/recipes/:id status=200
///   [Roost] GET /recipes/42 → RecipeController.show → 200 in 3.1ms
/// ```
///
/// The line is written once, after the response is ready, so concurrent
/// requests don't interleave. It also covers error responses: the action and
/// route are still reported when a controller throws.
///
/// Parameters whose names contain `passw`, `secret`, `token`, `_key`, `crypt`,
/// `salt`, `certificate`, `otp`, `ssn`, `cvv` or `cvc` are logged as
/// `[FILTERED]`, including inside JSON bodies.
///
/// - Parameters:
///   - filterParameters: More parameter names to hide, in addition to the defaults.
///   - logger: The swift-log logger. Request metadata is attached to each
///     line, so a JSON log handler receives it as fields.
public func roost_requestLogger(
    filterParameters: [String] = [],
    logger: Logger = Logger(label: "roost.request")
) -> Plug {
    let filters = (roost_filteredParameters + filterParameters).map { $0.lowercased() }
    return { conn in
        let start = ContinuousClock.now
        return conn.roost_recordingMatchedRoute().registerBeforeSend { c in
            // Read the request when the response is ready, after `methodOverride()` applied `_method`.
            let method = c.request.method.rawValue
            let path = (c.request.path ?? "/").split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
            let milliseconds = (ContinuousClock.now - start) / .milliseconds(1)
            let duration = String(format: "%.1f", milliseconds)
            let status = c.response.status.code
            let route = c.matchedRoute
            var metadata: Logger.Metadata = ["status": "\(status)", "duration_ms": "\(duration)"]
            if let id = c.requestId { metadata["request_id"] = "\(id)" }
            if let pattern = route.pattern { metadata["route"] = "\(pattern)" }
            var endpoint = ""
            if let controller = route.controller, let action = route.action {
                metadata["controller"] = "\(controller)"
                metadata["action"] = "\(action)"
                endpoint = " → \(controller).\(action)"
            }
            let params = c.roost_loggedParams(pathParams: route.pathParams, filters: filters)
            if !params.isEmpty {
                metadata["params"] = .dictionary(params.mapValues { .string($0) })
            }
            logger.info("\(method) \(path)\(endpoint) → \(status) in \(duration)ms", metadata: metadata)
            return c
        }
    }
}

extension Connection {
    /// Query, body, and path parameters with filtered names replaced by `[FILTERED]`.
    func roost_loggedParams(pathParams: [String: String], filters: [String]) -> [String: String] {
        func hidden(_ key: String) -> Bool {
            let key = key.lowercased()
            return filters.contains { key.contains($0) }
        }
        var params = queryParams
        params.merge(bodyParams) { $1 }
        if isJSONRequest, case .buffered(let data) = requestBody,
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (key, value) in object {
                params[key] = roost_filteredJSON(value, hidden: hidden)
            }
        }
        params.merge(self.params) { $1 }
        params.merge(pathParams) { $1 }
        for key in params.keys where hidden(key) {
            params[key] = "[FILTERED]"
        }
        return params
    }
}

/// Renders a JSON value for a log line, hiding filtered keys at any depth.
private func roost_filteredJSON(_ value: Any, hidden: (String) -> Bool) -> String {
    func filter(_ value: Any) -> Any {
        if let object = value as? [String: Any] {
            return object.reduce(into: [String: Any]()) { result, entry in
                result[entry.key] = hidden(entry.key) ? "[FILTERED]" : filter(entry.value)
            }
        }
        if let array = value as? [Any] { return array.map(filter) }
        return value
    }
    let filtered = filter(value)
    if let string = filtered as? String { return string }
    // Serialize numbers and Booleans too, so `true` is not logged as `1`.
    guard let data = try? JSONSerialization.data(withJSONObject: filtered, options: [.sortedKeys, .fragmentsAllowed]) else {
        return "\(filtered)"
    }
    return String(decoding: data, as: UTF8.self)
}
