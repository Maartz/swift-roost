import Foundation
import Hummingbird
import HummingbirdTesting
import Testing
@testable import Roost

@Suite("ServerConfig TLS")
struct ServerTLSTests {
    @Test func servesHTTPSWithTheConfiguredCertificate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let certificatePath = directory.appendingPathComponent("cert.pem").path
        let keyPath = directory.appendingPathComponent("key.pem").path
        try localhostCertificate.write(toFile: certificatePath, atomically: true, encoding: .utf8)
        try localhostKey.write(toFile: keyPath, atomically: true, encoding: .utf8)

        let config = ServerConfig(host: "127.0.0.1", port: 0, tls: .init(certificatePath: certificatePath, keyPath: keyPath))
        let app = Application(
            responder: NexusHummingbirdAdapter(plug: { conn in conn.text("secure") }),
            server: try config.serverBuilder(),
            configuration: .init(address: .hostname(config.host, port: config.port))
        )

        try await app.test(.ahc(.https)) { client in
            let response = try await client.execute(uri: "/", method: .get)
            #expect(response.status == .ok)
            #expect(String(buffer: response.body) == "secure")
        }
    }

    @Test func http2WithoutTLSStopsTheApp() {
        let config = ServerConfig(tls: nil, http2: true)
        #expect(throws: ServerConfigError.self) { try config.serverBuilder() }
    }
}

// A self-signed certificate for localhost, valid until 2126. Test use only.
let localhostCertificate = """
    -----BEGIN CERTIFICATE-----
    MIIBlTCCATugAwIBAgIUKyCZLDwXrJY3LTEMvUMDupeT3k0wCgYIKoZIzj0EAwIw
    FDESMBAGA1UEAwwJbG9jYWxob3N0MCAXDTI2MTAyMDE3MDQxOFoYDzIxMjYwOTI2
    MTcwNDE4WjAUMRIwEAYDVQQDDAlsb2NhbGhvc3QwWTATBgcqhkjOPQIBBggqhkjO
    PQMBBwNCAASPh/IJtyTKzNx+P/ckM79gS47qlyjZjeQqbik9gsIc1SFz9ZrtUE7y
    +oDQTL4UQEwDB/ccHfXflwy8anCJp8bgo2kwZzAdBgNVHQ4EFgQUl9TFEj0kWVZ6
    b8b2Q8e3WKYbEM4wHwYDVR0jBBgwFoAUl9TFEj0kWVZ6b8b2Q8e3WKYbEM4wDwYD
    VR0TAQH/BAUwAwEB/zAUBgNVHREEDTALgglsb2NhbGhvc3QwCgYIKoZIzj0EAwID
    SAAwRQIhAL42yL4n0nD4oNE0Kwl3YykUVydOvhW4YD88u5vEe7HmAiA+1b4f5aos
    dL5LBqDT7okP0OkT/TT2gKNFW+KhIHXD0g==
    -----END CERTIFICATE-----
    """

let localhostKey = """
    -----BEGIN PRIVATE KEY-----
    MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgh0RtLNmeCi+E77hA
    r6+UD4D1oa3rkYRL1uLFtLCOP1OhRANCAASPh/IJtyTKzNx+P/ckM79gS47qlyjZ
    jeQqbik9gsIc1SFz9ZrtUE7y+oDQTL4UQEwDB/ccHfXflwy8anCJp8bg
    -----END PRIVATE KEY-----
    """
