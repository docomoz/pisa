import XCTest

final class MCPTransportTests: XCTestCase {
    func testFreshServerAnswersEachRequestWhileInputStaysOpen() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let process = Process()
        process.executableURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("PisaMCP")
        var environment = ProcessInfo.processInfo.environment
        environment["CFFIXED_USER_HOME"] = home.path
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        func request(_ method: String) throws -> [String: Any]? {
            let line = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"\(method)\"}\n"
            try input.fileHandleForWriting.write(contentsOf: Data(line.utf8))
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 2_000) == 1, descriptor.revents & Int16(POLLIN) != 0 else {
                XCTFail("No response to \(method) while stdin is open")
                return nil
            }
            return try XCTUnwrap(JSONSerialization.jsonObject(with: output.fileHandleForReading.availableData) as? [String: Any])
        }

        guard let initialize = try request("initialize") else { return }
        let result = try XCTUnwrap(initialize["result"] as? [String: Any])
        XCTAssertNotNil(result["protocolVersion"])
        let meetings = home.appendingPathComponent("Library/Containers/com.docomoz.pisa/Data/Library/Application Support/Pisa/Meetings")
        guard FileManager.default.fileExists(atPath: meetings.path) else { return XCTFail("Server did not use the test library") }
        guard let list = try request("tools/list") else { return }
        let tools = (list["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.compactMap { $0["name"] as? String }, ["list_meetings", "search_meetings", "read_transcript", "list_folders", "search_transcripts"])
    }
}
