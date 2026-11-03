import XCTest
@testable import PisyaCore

final class NativeModelDownloadTests: XCTestCase {
    private func server() throws -> (Process, URL) {
        // A real loopback server exercises URLSession's delegate callbacks and cancellation.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", """
from http.server import BaseHTTPRequestHandler, HTTPServer
import time
class Handler(BaseHTTPRequestHandler):
 def log_message(self, *args): pass
 def do_GET(self):
  if self.path == '/error':
   self.send_response(503); self.end_headers(); return
  body = b'verified model fixture' if self.path == '/ok' else b'x' * 1048576
  self.send_response(200); self.send_header('Content-Length', str(len(body))); self.end_headers()
  try:
   for i in range(0, len(body), 1024):
    self.wfile.write(body[i:i+1024]); self.wfile.flush()
    if self.path == '/slow': time.sleep(.02)
  except (BrokenPipeError, ConnectionResetError): pass
server = HTTPServer(('127.0.0.1', 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
"""]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        var bytes = Data()
        while let byte = try pipe.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
            if byte == Data([10]) { break }; bytes.append(byte)
        }
        guard let text = String(data: bytes, encoding: .utf8), let port = Int(text) else { process.terminate(); throw URLError(.cannotConnectToHost) }
        return (process, URL(string: "http://127.0.0.1:\(port)")!)
    }
    func testNativeTransportDownloadsToDisk() async throws {
        let (server, base) = try server(); defer { server.terminate(); server.waitUntilExit() }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        try await NativeModelDownload.fetch(base.appendingPathComponent("ok"), to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data("verified model fixture".utf8))
    }
    func testNativeTransportRejectsHTTPErrorAndCanRetry() async throws {
        let (server, base) = try server(); defer { server.terminate(); server.waitUntilExit() }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        do { try await NativeModelDownload.fetch(base.appendingPathComponent("error"), to: destination); XCTFail("HTTP 503 accepted") }
        catch { guard case ModelInstallError.http(503) = error else { return XCTFail("Unexpected error: \(error)") } }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        try await NativeModelDownload.fetch(base.appendingPathComponent("ok"), to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data("verified model fixture".utf8))
    }
    func testTaskCancellationStopsActualNativeTransfer() async throws {
        let (server, base) = try server(); defer { server.terminate(); server.waitUntilExit() }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        let task = Task { try await NativeModelDownload.fetch(base.appendingPathComponent("slow"), to: destination) }
        try await Task.sleep(nanoseconds: 150_000_000)
        task.cancel()
        do { try await task.value; XCTFail("Cancellation ignored") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
}
