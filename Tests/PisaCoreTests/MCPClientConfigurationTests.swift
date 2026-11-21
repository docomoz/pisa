import Foundation
import XCTest
@testable import PisaCore

final class MCPClientConfigurationTests: XCTestCase {
    private let paths = [
        "/Applications/Pisa.app/Contents/Helpers/pisa-mcp",
        "/Volumes/Архив встреч/Pisa Test.app/Contents/Helpers/pisa-mcp",
        "/Applications/Pisa's \"local\" \\build.app/Contents/Helpers/pisa-mcp"
    ]

    func testDesktopAndCursorJSONPreserveTheExecutablePath() throws {
        for path in paths {
            for explicitStdio in [false, true] {
                let configuration = MCPClientConfiguration.json(commandPath: path, explicitStdio: explicitStdio)
                let object = try JSONSerialization.jsonObject(with: Data(configuration.utf8))
                let json = try XCTUnwrap(object as? [String: [String: [String: String]]])
                XCTAssertEqual(json["mcpServers"]?["pisa"]?["command"], path)
                XCTAssertEqual(json["mcpServers"]?["pisa"]?["type"], explicitStdio ? "stdio" : nil)
                XCTAssertGreaterThan(configuration.split(separator: "\n").count, 1)
            }
        }
    }

    func testClaudeCodePassesThePathAsOneLiteralShellArgument() throws {
        for path in paths {
            let configuration = MCPClientConfiguration.claudeCode(commandPath: path)
            let shell = Process()
            let output = Pipe()
            shell.executableURL = URL(fileURLWithPath: "/bin/sh")
            // Replace the real client with a function that reports its arguments.
            shell.arguments = ["-c", "claude() { printf '%s\\n' \"$@\"; }; " + configuration]
            shell.standardOutput = output
            try shell.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            shell.waitUntilExit()
            XCTAssertEqual(shell.terminationStatus, 0)
            XCTAssertEqual(String(decoding: data, as: UTF8.self).components(separatedBy: "\n"),
                           ["mcp", "add", "--transport", "stdio", "pisa", "--", path, ""])
        }
    }
}
