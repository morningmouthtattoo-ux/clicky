//
//  BlenderBridge.swift
//  leanring-buddy
//
//  Direct bridge to a running Blender instance via the official Blender Lab
//  "MCP" add-on (blender.org/lab/mcp-server). That add-on runs a tiny TCP
//  socket server inside Blender — by default on localhost:9876 — and
//  auto-starts when Blender launches.
//
//  Wire protocol (mirrored from the add-on's mcp_to_blender_server.py):
//    • Request:  null-byte-terminated JSON
//        {"type":"execute","code":"<python>","strict_json":true}\0
//    • Response: null-byte-terminated JSON
//        {"status":"ok","result":{...}}            (success)
//        {"status":"error","message":"<traceback>"} (failure)
//      Responses may also carry "stdout"/"stderr" keys.
//
//  The add-on opens a fresh connection per request and closes it after
//  replying, so this bridge opens one short-lived connection per command.
//  No extra server process, no Python middleman — Blender just runs the
//  Python we send and hands back JSON.
//

import Foundation
import Network

/// Serializes all access to the Blender socket so two voice commands can't
/// interleave their requests on the same connection. Each `runPython` call
/// opens its own connection, but the actor guarantees one-at-a-time ordering.
actor BlenderBridge {

    // MARK: - Public result + error types

    /// The outcome of running a snippet of Blender Python.
    struct BlenderRunResult {
        /// True when Blender reported `{"status":"ok"}`.
        let didSucceed: Bool
        /// A human- and Claude-readable summary of what came back. For a
        /// success this is the JSON of the `result` value; for a failure it's
        /// the error message. Always safe to feed straight back to Claude.
        let summaryForModel: String
        /// Anything the Python code printed, if present.
        let standardOutput: String?
        /// Any error text Blender captured, if present.
        let standardError: String?
    }

    /// Friendly, specific errors so the rest of the app can explain what went
    /// wrong in plain language (e.g. "Blender doesn't seem to be running").
    enum BlenderBridgeError: LocalizedError {
        case couldNotConnect
        case connectionDropped
        case timedOut
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .couldNotConnect:
                return "Couldn't reach Blender. Make sure Blender is open and the MCP add-on is enabled (it listens on localhost:9876)."
            case .connectionDropped:
                return "The connection to Blender dropped before it finished replying."
            case .timedOut:
                return "Blender took too long to respond."
            case .malformedResponse:
                return "Blender sent back something we couldn't read."
            }
        }
    }

    // MARK: - Configuration

    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    /// How long to wait for a single command to complete before giving up.
    private let perRequestTimeoutSeconds: TimeInterval

    init(host: String = "localhost", port: UInt16 = 9876, perRequestTimeoutSeconds: TimeInterval = 30) {
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(rawValue: port)!
        self.perRequestTimeoutSeconds = perRequestTimeoutSeconds
    }

    // MARK: - High-level convenience

    /// Quick liveness check — returns true if Blender answers at all.
    func isBlenderReachable() async -> Bool {
        do {
            let result = try await runPython("result = {\"ok\": True}")
            return result.didSucceed
        } catch {
            return false
        }
    }

    /// Returns a compact description of every object in the current scene
    /// (name + type + location). Handy for Claude to "look before it leaps".
    func describeSceneObjects() async throws -> BlenderRunResult {
        let introspectionCode = """
        import bpy
        scene_objects = []
        for scene_object in bpy.context.scene.objects:
            scene_objects.append({
                "name": scene_object.name,
                "type": scene_object.type,
                "location": [round(value, 4) for value in scene_object.location],
                "selected": scene_object.select_get(),
            })
        active_object = bpy.context.view_layer.objects.active
        result = {
            "objects": scene_objects,
            "active_object": active_object.name if active_object else None,
            "mode": bpy.context.mode,
        }
        """
        return try await runPython(introspectionCode)
    }

    // MARK: - Core request/response

    /// Sends one snippet of Python to Blender and returns the decoded result.
    /// The Python must assign a JSON-serializable dict to a variable named
    /// `result` (the add-on contract); on success that dict comes back to us.
    func runPython(_ pythonCode: String) async throws -> BlenderRunResult {
        let requestObject: [String: Any] = [
            "type": "execute",
            "code": pythonCode,
            "strict_json": false,
        ]
        let requestData = try JSONSerialization.data(withJSONObject: requestObject)

        // The add-on delimits messages with a single null byte.
        var framedRequest = requestData
        framedRequest.append(0x00)

        let responseData = try await sendAndReceive(framedRequest)
        return try decodeResponse(responseData)
    }

    // MARK: - Networking (NWConnection wrapped in async/await)

    /// Opens a fresh TCP connection, sends the framed request, reads bytes
    /// until the null-byte terminator arrives, then tears the connection down.
    private func sendAndReceive(_ framedRequest: Data) async throws -> Data {
        let connection = NWConnection(host: host, port: port, using: .tcp)

        // A small box so the connection's callbacks and the timeout can race
        // to resume the continuation exactly once.
        final class ResumeGuard {
            var hasResumed = false
        }
        let resumeGuard = ResumeGuard()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                let accumulatedBytes = NSMutableData()

                func finish(_ result: Result<Data, Error>) {
                    if resumeGuard.hasResumed { return }
                    resumeGuard.hasResumed = true
                    connection.cancel()
                    continuation.resume(with: result)
                }

                // Give up if Blender never finishes replying.
                let timeoutWorkItem = DispatchWorkItem {
                    finish(.failure(BlenderBridgeError.timedOut))
                }
                DispatchQueue.global().asyncAfter(
                    deadline: .now() + perRequestTimeoutSeconds,
                    execute: timeoutWorkItem
                )

                // Reads chunks until the null terminator shows up in the buffer.
                func receiveNextChunk() {
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { chunk, _, isComplete, receiveError in
                        if let chunk, !chunk.isEmpty {
                            accumulatedBytes.append(chunk)
                            let bytes = accumulatedBytes as Data
                            if bytes.firstIndex(of: 0x00) != nil {
                                timeoutWorkItem.cancel()
                                finish(.success(bytes))
                                return
                            }
                        }

                        if let receiveError {
                            timeoutWorkItem.cancel()
                            finish(.failure(receiveError))
                            return
                        }

                        if isComplete {
                            timeoutWorkItem.cancel()
                            // Connection closed. If we already have bytes, use them;
                            // otherwise the peer dropped us early.
                            let bytes = accumulatedBytes as Data
                            if bytes.isEmpty {
                                finish(.failure(BlenderBridgeError.connectionDropped))
                            } else {
                                finish(.success(bytes))
                            }
                            return
                        }

                        receiveNextChunk()
                    }
                }

                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        // Connection is up — send the request, then start reading.
                        connection.send(content: framedRequest, completion: .contentProcessed { sendError in
                            if let sendError {
                                timeoutWorkItem.cancel()
                                finish(.failure(sendError))
                                return
                            }
                            receiveNextChunk()
                        })
                    case .failed:
                        timeoutWorkItem.cancel()
                        finish(.failure(BlenderBridgeError.couldNotConnect))
                    case .cancelled:
                        // Normal teardown after finish() — nothing to do.
                        break
                    default:
                        break
                    }
                }

                connection.start(queue: DispatchQueue.global())
            }
        } onCancel: {
            connection.cancel()
        }
    }

    /// Parses the add-on's null-terminated JSON response into a result the rest
    /// of the app (and Claude) can consume.
    private func decodeResponse(_ responseData: Data) throws -> BlenderRunResult {
        // Strip everything from the first null byte onward.
        let jsonBytes: Data
        if let terminatorIndex = responseData.firstIndex(of: 0x00) {
            jsonBytes = responseData.prefix(upTo: terminatorIndex)
        } else {
            jsonBytes = responseData
        }

        guard let parsed = try? JSONSerialization.jsonObject(with: jsonBytes) as? [String: Any] else {
            throw BlenderBridgeError.malformedResponse
        }

        let status = parsed["status"] as? String
        let standardOutput = parsed["stdout"] as? String
        let standardError = parsed["stderr"] as? String

        if status == "ok" {
            // Re-serialize the `result` value to a clean JSON string for Claude.
            let resultSummary: String
            if let resultValue = parsed["result"],
               let prettyData = try? JSONSerialization.data(withJSONObject: resultValue, options: [.sortedKeys]),
               let prettyString = String(data: prettyData, encoding: .utf8) {
                resultSummary = prettyString
            } else {
                resultSummary = "ok"
            }
            return BlenderRunResult(
                didSucceed: true,
                summaryForModel: resultSummary,
                standardOutput: standardOutput,
                standardError: standardError
            )
        } else {
            let message = parsed["message"] as? String ?? "Unknown Blender error"
            return BlenderRunResult(
                didSucceed: false,
                summaryForModel: "Blender error: \(message)",
                standardOutput: standardOutput,
                standardError: standardError
            )
        }
    }
}
