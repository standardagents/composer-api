@testable import CursorAPICore
import XCTest

final class ProtobufTests: XCTestCase {
    func testRunRequestContainsPromptAndModel() {
        let request = CursorSDKProto.runRequest(agentID: "agent-id", messageID: "message-id", modelID: "composer-2.5", prompt: "hello")
        let fields = Proto.decodeFields(request)
        XCTAssertEqual(fields.count, 1)
        guard case .bytes(let runEnvelope)? = fields.first?.value else {
            XCTFail("Expected envelope")
            return
        }
        let runFields = Proto.decodeFields(runEnvelope)
        XCTAssertEqual(Proto.stringField(runFields, 5), "agent-id")
        XCTAssertEqual(Proto.stringField(runFields, 13), "sdk")
    }

    func testConnectFrameRoundTrip() {
        let payload = Data("abc".utf8)
        let frame = ConnectProto.frame(payload)
        XCTAssertEqual(ConnectProto.frames(from: frame), [payload])
    }

    func testRequestContextDecode() {
        let context = CursorSDKProto.requestContextResult(id: 42, execID: "exec-1")
        let fields = Proto.decodeFields(context)
        guard case .bytes(let execMessage)? = fields.first(where: { $0.number == 2 })?.value else {
            XCTFail("Expected exec message")
            return
        }
        let serverLikeFrame = Proto.message([Proto.messageField(2, execMessage)])
        XCTAssertEqual(CursorSDKRequestContext.decode(serverLikeFrame), CursorSDKRequestContext(id: 42, execID: "exec-1"))
    }

    func testRequestContextUsesHarnessWorkingDirectory() throws {
        let context = CursorSDKProto.requestContextResult(id: 42, execID: "exec-1", workingDirectory: "/tmp/project")
        let execMessage = try XCTUnwrap(Proto.dataField(Proto.decodeFields(context), 2))
        let result = try XCTUnwrap(Proto.dataField(Proto.decodeFields(execMessage), 10))
        let success = try XCTUnwrap(Proto.dataField(Proto.decodeFields(result), 1))
        let requestContext = try XCTUnwrap(Proto.dataField(Proto.decodeFields(success), 1))
        let env = try XCTUnwrap(Proto.dataField(Proto.decodeFields(requestContext), 4))
        let envFields = Proto.decodeFields(env)

        XCTAssertEqual(Proto.stringField(envFields, 2), "/tmp/project")
        XCTAssertEqual(Proto.stringField(envFields, 11), "/tmp/project")
        XCTAssertEqual(Proto.stringField(envFields, 21), "/tmp/project")
    }

    func testLocalHarnessUsesSDKRunIDPrefix() {
        let runID = LocalCursorSDKHarness.newRunID()
        XCTAssertTrue(runID.hasPrefix("run-"))
        XCTAssertFalse(runID.hasPrefix("msg-"))
    }

    func testDetectsSDKTurnEndedMarker() {
        let turnEnded = Proto.message([Proto.varintField(2, 1)])
        let interaction = Proto.message([Proto.messageField(14, turnEnded)])
        let frame = Proto.message([Proto.messageField(1, interaction)])

        XCTAssertTrue(CursorSDKStreamMarkers.hasTurnEnded(frame))
        XCTAssertFalse(CursorSDKStreamMarkers.hasTurnEnded(Proto.message([Proto.messageField(1, Proto.message([]))])))
    }

    func testDetectsSDKToolCallMarkers() {
        let shellArgs = Proto.message([Proto.stringField(1, "pwd")])
        let execShell = Proto.message([Proto.messageField(2, shellArgs)])
        let execFrame = Proto.message([Proto.messageField(2, execShell)])

        let interactionShell = Proto.message([Proto.messageField(1, shellArgs)])
        let toolCallUpdate = Proto.message([Proto.messageField(2, interactionShell)])
        let interaction = Proto.message([Proto.messageField(2, toolCallUpdate)])
        let interactionFrame = Proto.message([Proto.messageField(1, interaction)])

        let context = CursorSDKProto.requestContextResult(id: 42, execID: "exec-1")
        let contextFields = Proto.decodeFields(context)
        guard case .bytes(let execMessage)? = contextFields.first(where: { $0.number == 2 })?.value else {
            XCTFail("Expected exec message")
            return
        }
        let contextFrame = Proto.message([Proto.messageField(2, execMessage)])

        XCTAssertTrue(CursorSDKStreamMarkers.hasToolCall(execFrame))
        XCTAssertTrue(CursorSDKStreamMarkers.hasToolCall(interactionFrame))
        XCTAssertFalse(CursorSDKStreamMarkers.hasToolCall(contextFrame))
    }

    func testDecodesSDKMCPArgsMap() throws {
        let mcpArgs = Proto.message([
            Proto.stringField(1, "write_file"),
            Proto.messageField(2, protoValueMapEntry("file_path", protoStringValue("src/App.tsx"))),
            Proto.messageField(2, protoValueMapEntry("overwrite", protoBoolValue(true))),
            Proto.stringField(3, "call-mcp-1"),
            Proto.stringField(4, "filesystem"),
            Proto.stringField(5, "write_file")
        ])
        let mcpTool = Proto.message([Proto.messageField(1, mcpArgs)])
        let toolCallUpdate = Proto.message([Proto.messageField(2, Proto.message([Proto.messageField(15, mcpTool)]))])
        let interaction = Proto.message([Proto.messageField(2, toolCallUpdate)])
        let frame = Proto.message([Proto.messageField(1, interaction)])

        var decoder = CursorSDKFrameDecoder()
        let events = decoder.push(frame)

        guard case .toolCall(let toolCall)? = events.first else {
            XCTFail("Expected MCP tool call")
            return
        }
        XCTAssertEqual(toolCall.name, "mcp")
        XCTAssertEqual(toolCall.arguments["name"]?.stringValue, "write_file")
        XCTAssertEqual(toolCall.arguments["providerIdentifier"]?.stringValue, "filesystem")
        XCTAssertEqual(toolCall.arguments["toolName"]?.stringValue, "write_file")
        XCTAssertEqual(toolCall.arguments["toolCallId"]?.stringValue, "call-mcp-1")
        let args = try XCTUnwrap(toolCall.arguments["args"]?.objectValue)
        XCTAssertEqual(args["file_path"]?.stringValue, "src/App.tsx")
        XCTAssertEqual(args["overwrite"], .bool(true))
    }

    func testSDKToolCallEmissionRequiresCompleteExecutableArguments() {
        XCTAssertFalse(CursorSDKToolSpec.isEmittable(CursorToolCall(name: "glob", arguments: [:])))
        XCTAssertTrue(CursorSDKToolSpec.isEmittable(CursorToolCall(name: "glob", arguments: ["globPattern": .string("**/*.tsx")])))
        XCTAssertTrue(CursorSDKToolSpec.isEmittable(CursorToolCall(name: "glob", arguments: ["targetDirectory": .string("src")])))
        XCTAssertTrue(CursorSDKToolSpec.isEmittable(CursorToolCall(name: "glob", arguments: ["targetDirectory": .string("src/**/*.tsx")])))

        XCTAssertFalse(CursorSDKToolSpec.isEmittable(CursorToolCall(name: "edit", arguments: ["path": .string("src/App.tsx"), "oldText": .string("old")])))
        XCTAssertFalse(CursorSDKToolSpec.isEmittable(CursorToolCall(name: "edit", arguments: ["path": .string("src/App.tsx"), "newText": .string("new")])))
        XCTAssertTrue(CursorSDKToolSpec.isEmittable(CursorToolCall(name: "edit", arguments: ["path": .string("src/App.tsx"), "oldText": .string(""), "newText": .string("new")])))
        XCTAssertTrue(CursorSDKToolSpec.isEmittable(CursorToolCall(name: "edit", arguments: ["filePath": .string("src/App.tsx"), "old_str": .string("old"), "replacement": .string("")])))
        XCTAssertTrue(CursorSDKToolSpec.isEmittable(CursorToolCall(name: "edit", arguments: ["path": .string("src/App.tsx"), "patch_content": .string("")])))

        XCTAssertFalse(CursorSDKToolSpec.isEmittable(CursorToolCall(name: "write", arguments: ["path": .string("empty.txt")])))
        XCTAssertTrue(CursorSDKToolSpec.isEmittable(CursorToolCall(name: "write", arguments: ["path": .string("empty.txt"), "fileText": .string("")])))
        XCTAssertTrue(CursorSDKToolSpec.isEmittable(CursorToolCall(name: "write", arguments: ["filePath": .string("empty.txt"), "content": .string("")])))

        XCTAssertFalse(CursorSDKToolSpec.isEmittable(CursorToolCall(name: "mcp", arguments: ["providerIdentifier": .string("filesystem")])))
        XCTAssertTrue(CursorSDKToolSpec.isEmittable(CursorToolCall(name: "mcp", arguments: ["providerIdentifier": .string("filesystem"), "toolName": .string("write_file")])))
    }

    func testSDKStreamingEditNormalizationSupportsSnakeCaseAndEmptyContent() {
        let normalized = CursorSDKToolSpec.normalizedForOpenCode(
            CursorToolCall(name: "edit", arguments: ["path": .string("scripts/empty.mjs"), "stream_content": .string("")])
        )

        XCTAssertEqual(normalized.name, "write")
        XCTAssertEqual(normalized.arguments["path"], .string("scripts/empty.mjs"))
        XCTAssertEqual(normalized.arguments["fileText"], .string(""))
    }

    func testNativeTransportConsumesRequestContextBeforeTurnEndDetection() {
        let context = CursorSDKProto.requestContextResult(id: 42, execID: "exec-1")
        let fields = Proto.decodeFields(context)
        guard case .bytes(let execMessage)? = fields.first(where: { $0.number == 2 })?.value else {
            XCTFail("Expected exec message")
            return
        }
        let turnEnded = Proto.message([Proto.varintField(2, 1)])
        let interaction = Proto.message([Proto.messageField(14, turnEnded)])
        let combined = Proto.message([
            Proto.messageField(2, execMessage),
            Proto.messageField(1, interaction)
        ])

        let beforeContext = CursorSDKFrameRouter.action(for: combined, requestContextAlreadySent: false)
        XCTAssertEqual(beforeContext.requestContext, CursorSDKRequestContext(id: 42, execID: "exec-1"))
        XCTAssertFalse(beforeContext.shouldForwardToDecoder)
        XCTAssertFalse(beforeContext.isTurnEnded)

        let afterContext = CursorSDKFrameRouter.action(for: combined, requestContextAlreadySent: true)
        XCTAssertNil(afterContext.requestContext)
        XCTAssertTrue(afterContext.shouldForwardToDecoder)
        XCTAssertTrue(afterContext.isTurnEnded)
        XCTAssertFalse(afterContext.hasToolCall)
    }

    private func protoValueMapEntry(_ key: String, _ value: Data) -> Data {
        Proto.message([
            Proto.stringField(1, key),
            Proto.messageField(2, value)
        ])
    }

    private func protoStringValue(_ value: String) -> Data {
        Proto.message([Proto.stringField(3, value)])
    }

    private func protoBoolValue(_ value: Bool) -> Data {
        Proto.message([Proto.boolField(4, value)])
    }
}
