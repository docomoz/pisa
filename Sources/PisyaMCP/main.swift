import Foundation
#if !XCODE_BUILD
import PisyaCore
#endif
let home = FileManager.default.homeDirectoryForCurrentUser
let root = home.appendingPathComponent("Library/Containers/com.docomoz.pisya/Data/Library/Application Support/Pisya")
do {
    let library = try MeetingLibrary(root: root)
    let handler = MCPHandler(library: library)
    var buffer = Data()
    while let chunk = try FileHandle.standardInput.read(upToCount: 4096), !chunk.isEmpty {
        buffer.append(chunk)
        if buffer.count > 1_048_576 { exit(1) }
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer[..<end]; buffer.removeSubrange(...end)
            let response: [String: Any]?
            if let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                response = handler.handle(request)
            } else { response = ["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]] }
            if let response, var data = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]) {
                data.append(10); FileHandle.standardOutput.write(data)
            }
        }
    }
} catch { FileHandle.standardError.write(Data("Cannot open Pisya library\n".utf8)); exit(1) }
