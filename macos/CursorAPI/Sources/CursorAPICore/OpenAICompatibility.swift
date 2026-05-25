import Foundation

public struct OpenAIToolSpec: Codable, Equatable, Sendable {
    public var name: String
    public var description: String?
    public var parameters: JSONValue?
}

public struct PreparedChatRequest: Equatable, Sendable {
    public var model: String
    public var cursorModelID: String
    public var prompt: String
    public var stream: Bool
    public var promptCharacters: Int
    public var tools: [OpenAIToolSpec]
    public var sessionKey: String?
    public var requestedSessionKey: String?
    public var previousResponseID: String?
    public var storeResponse: Bool
    public var responseInputItems: [JSONValue]
}

public enum OpenAICompatibility {
    public static func modelList() -> [String: Any] {
        [
            "object": "list",
            "data": ComposerModels.all.map { model in
                [
                    "id": model.id,
                    "object": "model",
                    "created": 1_779_148_800,
                    "owned_by": "cursor",
                    "name": model.name,
                    "cost": [
                        "input": model.inputCost,
                        "output": model.outputCost
                    ]
                ] as [String: Any]
            }
        ]
    }

    public static func prepareChatRequest(_ body: Data) throws -> PreparedChatRequest {
        let raw = try jsonObject(body)
        guard let messages = raw["messages"] as? [[String: Any]] else {
            throw CursorAPIError.badRequest("messages must be an array.")
        }
        let tools = parseTools(raw["tools"], disabled: (raw["tool_choice"] as? String) == "none")
        let requestedModel = (raw["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = requestedModel?.isEmpty == false ? requestedModel! : "composer-2.5"
        var transcript = [
            "You are running through a local Cursor SDK-compatible harness.",
            "The client owns local tool execution. When local inspection, shell commands, or file changes are needed, request a tool call and wait for the tool result.",
            "When the conversation includes LOCAL TOOL RESULT records, treat them as completed SDK tool_call results for your previous tool requests and continue from those results.",
            "For creating new files, request write calls with both path and fileText.",
            "When starting a dev server or other long-running watcher, start it in the background with output redirected and return immediately.",
            "Do not say that agent mode or tools are unavailable."
        ]
        appendToolInventory(&transcript, tools: tools, toolChoice: raw["tool_choice"])
        transcript.append("")
        transcript.append("Conversation:")
        var rememberedToolCalls: [String: (name: String, arguments: [String: Any])] = [:]

        for item in messages {
            let role = (item["role"] as? String) ?? "user"
            let text = contentText(item["content"], role: role)
            if role == "tool" {
                let toolCallID = (item["tool_call_id"] as? String) ?? ""
                let toolName = (item["name"] as? String) ?? rememberedToolCalls[toolCallID]?.name ?? ""
                let label = [toolName.isEmpty ? nil : "name=\(toolName)", toolCallID.isEmpty ? nil : "tool_call_id=\(toolCallID)"]
                    .compactMap { $0 }
                    .joined(separator: " ")
                transcript.append("TOOL RESULT\(label.isEmpty ? "" : " (\(label))"): \(text.isEmpty ? "[empty]" : text)")
                transcript.append("LOCAL TOOL RESULT: \(toolResultFeedback(toolCallID: toolCallID, toolName: toolName, text: text, remembered: rememberedToolCalls))")
            } else {
                transcript.append("\(role.uppercased()): \(text.isEmpty ? "[empty]" : text)")
            }

            if let toolCalls = item["tool_calls"] as? [[String: Any]] {
                if let data = try? JSONSerialization.data(withJSONObject: toolCalls, options: [.withoutEscapingSlashes]),
                   let json = String(data: data, encoding: .utf8) {
                    transcript.append("\(role.uppercased()) TOOL_CALLS: \(json)")
                }
                rememberToolCalls(toolCalls, into: &rememberedToolCalls)
            }
        }
        appendOptions(&transcript, raw)
        let prompt = transcript.joined(separator: "\n")
        return PreparedChatRequest(
            model: model,
            cursorModelID: ComposerModels.cursorModelID(for: model),
            prompt: prompt,
            stream: raw["stream"] as? Bool == true,
            promptCharacters: prompt.count,
            tools: tools,
            sessionKey: nil,
            requestedSessionKey: nil,
            previousResponseID: nil,
            storeResponse: false,
            responseInputItems: []
        )
    }

    public static func prepareResponsesRequest(_ body: Data) throws -> PreparedChatRequest {
        let raw = try jsonObject(body)
        let requestedModel = (raw["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = requestedModel?.isEmpty == false ? requestedModel! : "composer-2.5"
        let instructions = (raw["instructions"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let tools = parseTools(raw["tools"], disabled: (raw["tool_choice"] as? String) == "none")
        let previousResponseID = (raw["previous_response_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        var transcript = [
            "You are running through a local Cursor SDK-compatible harness.",
            "The client owns local tool execution. When local inspection, shell commands, or file changes are needed, request a function_call and wait for the function_call_output.",
            "When the input includes function_call_output records, treat them as completed local tool results for your previous function_call requests and continue from those results.",
            "For creating new files, request write calls with both path and fileText.",
            "When starting a dev server or other long-running watcher, start it in the background with output redirected and return immediately.",
            "Do not say that agent mode or tools are unavailable."
        ]
        appendToolInventory(&transcript, tools: tools, toolChoice: raw["tool_choice"])
        if let instructions, !instructions.isEmpty {
            transcript.append("")
            transcript.append("INSTRUCTIONS:")
            transcript.append(instructions)
        }
        transcript.append("")
        transcript.append("INPUT:")
        var rememberedToolCalls: [String: (name: String, arguments: [String: Any])] = [:]
        let input = raw["input"]
        let appendedInput = appendResponsesInput(input, to: &transcript, remembered: &rememberedToolCalls)
        if !appendedInput {
            transcript.append("[empty]")
        }
        appendOptions(&transcript, raw)
        let prompt = transcript.joined(separator: "\n")
        return PreparedChatRequest(
            model: model,
            cursorModelID: ComposerModels.cursorModelID(for: model),
            prompt: prompt,
            stream: raw["stream"] as? Bool == true,
            promptCharacters: prompt.count,
            tools: tools,
            sessionKey: nil,
            requestedSessionKey: responseSessionHint(raw),
            previousResponseID: previousResponseID,
            storeResponse: raw["store"] as? Bool ?? true,
            responseInputItems: normalizedResponseInputItems(input)
        )
    }

    public static func responseInputItemsObject(_ inputItems: [JSONValue]) -> [String: Any] {
        let data = inputItems.map(\.foundationValue)
        let firstID = inputItems.first.flatMap(responseInputItemID) as Any? ?? NSNull()
        let lastID = inputItems.last.flatMap(responseInputItemID) as Any? ?? NSNull()
        return [
            "object": "list",
            "data": data,
            "first_id": firstID,
            "last_id": lastID,
            "has_more": false
        ]
    }

    public static func chatCompletionResponse(
        id: String,
        created: Int,
        prepared: PreparedChatRequest,
        output: CursorSDKOutput
    ) -> [String: Any] {
        let toolCalls = toOpenAIToolCalls(output.toolCalls, tools: prepared.tools, responseID: id)
        let content: Any = toolCalls.isEmpty || !output.text.isEmpty ? output.text : NSNull()
        return [
            "id": id,
            "object": "chat.completion",
            "created": created,
            "model": prepared.model,
            "choices": [
                [
                    "index": 0,
                    "message": [
                        "role": "assistant",
                        "content": content,
                        "tool_calls": toolCalls,
                        "refusal": NSNull(),
                        "annotations": []
                    ],
                    "logprobs": NSNull(),
                    "finish_reason": toolCalls.isEmpty ? "stop" : "tool_calls"
                ]
            ],
            "usage": usage(promptCharacters: prepared.promptCharacters, completionCharacters: output.text.count + serializedLength(toolCalls)),
            "service_tier": "default",
            "system_fingerprint": NSNull(),
            "cursor_agent_id": output.agentID,
            "cursor_run_id": output.runID
        ]
    }

    public static func chatCompletionStream(
        id: String,
        created: Int,
        prepared: PreparedChatRequest,
        output: CursorSDKOutput
    ) throws -> Data {
        var data = Data()
        data.append(chatCompletionStreamStart(id: id, created: created, model: prepared.model))
        if !output.text.isEmpty {
            data.append(chatCompletionStreamText(id: id, created: created, model: prepared.model, delta: output.text))
        }
        for (index, toolCall) in output.toolCalls.enumerated() {
            data.append(chatCompletionStreamToolCall(id: id, created: created, prepared: prepared, toolCall: toolCall, index: index))
        }
        data.append(chatCompletionStreamFinish(id: id, created: created, model: prepared.model, emittedToolCallCount: output.toolCalls.count))
        data.append(chatCompletionStreamDone())
        return data
    }

    public static func chatCompletionStreamStart(id: String, created: Int, model: String) -> Data {
        sse([
            "id": id,
            "object": "chat.completion.chunk",
            "created": created,
            "model": model,
            "system_fingerprint": NSNull(),
            "choices": [["index": 0, "delta": ["role": "assistant"], "logprobs": NSNull(), "finish_reason": NSNull()]]
        ])
    }

    public static func chatCompletionStreamText(id: String, created: Int, model: String, delta: String) -> Data {
        guard !delta.isEmpty else { return Data() }
        return sse([
            "id": id,
            "object": "chat.completion.chunk",
            "created": created,
            "model": model,
            "system_fingerprint": NSNull(),
            "choices": [["index": 0, "delta": ["content": delta], "logprobs": NSNull(), "finish_reason": NSNull()]]
        ])
    }

    public static func chatCompletionStreamToolCall(
        id: String,
        created: Int,
        prepared: PreparedChatRequest,
        toolCall: CursorToolCall,
        index: Int
    ) -> Data {
        let converted = toOpenAIToolCalls([toolCall], tools: prepared.tools, responseID: "\(id)_\(index)").first ?? [
            "id": "call_\(index)",
            "type": "function",
            "function": ["name": toolCall.name, "arguments": jsonString(toolCall.arguments.mapValues(\.foundationValue))]
        ]
        return sse([
            "id": id,
            "object": "chat.completion.chunk",
            "created": created,
            "model": prepared.model,
            "system_fingerprint": NSNull(),
            "choices": [["index": 0, "delta": ["tool_calls": [["index": index] + converted]], "logprobs": NSNull(), "finish_reason": NSNull()]]
        ])
    }

    public static func chatCompletionStreamFinish(id: String, created: Int, model: String, emittedToolCallCount: Int) -> Data {
        sse([
            "id": id,
            "object": "chat.completion.chunk",
            "created": created,
            "model": model,
            "system_fingerprint": NSNull(),
            "choices": [["index": 0, "delta": [:], "logprobs": NSNull(), "finish_reason": emittedToolCallCount == 0 ? "stop" : "tool_calls"]]
        ])
    }

    public static func chatCompletionStreamDone() -> Data {
        Data("data: [DONE]\n\n".utf8)
    }

    public static func responseObject(
        id: String,
        created: Int,
        prepared: PreparedChatRequest,
        output: CursorSDKOutput
    ) -> [String: Any] {
        let messageID = "msg_\(id.dropFirst(5))"
        let toolCallItems = responseToolCallItems(output.toolCalls, prepared: prepared, responseID: id)
        var outputItems: [[String: Any]] = []
        if !output.text.isEmpty || output.toolCalls.isEmpty {
            outputItems.append([
                "id": messageID,
                "type": "message",
                "status": "completed",
                "role": "assistant",
                "content": [
                    [
                        "type": "output_text",
                        "text": output.text,
                        "annotations": []
                    ]
                ]
            ])
        }
        outputItems.append(contentsOf: toolCallItems)
        return [
            "id": id,
            "object": "response",
            "created_at": created,
            "status": "completed",
            "completed_at": Int(Date().timeIntervalSince1970),
            "error": NSNull(),
            "incomplete_details": NSNull(),
            "model": prepared.model,
            "output": outputItems,
            "parallel_tool_calls": true,
            "previous_response_id": (prepared.previousResponseID as Any?) ?? NSNull(),
            "reasoning": ["effort": NSNull(), "summary": NSNull()],
            "store": prepared.storeResponse,
            "tool_choice": "auto",
            "tools": [],
            "truncation": "disabled",
            "usage": usage(promptCharacters: prepared.promptCharacters, completionCharacters: output.text.count + serializedLength(toolCallItems)),
            "user": NSNull(),
            "metadata": [:],
            "cursor_agent_id": output.agentID,
            "cursor_run_id": output.runID
        ]
    }

    public static func responseStream(
        id: String,
        created: Int,
        prepared: PreparedChatRequest,
        output: CursorSDKOutput
    ) -> Data {
        var data = Data()
        for chunk in responseStreamStart(id: id, created: created, prepared: prepared) {
            data.append(chunk)
        }
        var outputIndex = 0
        let includeMessage = !output.text.isEmpty || output.toolCalls.isEmpty
        if includeMessage {
            for chunk in responseStreamTextStart(id: id, outputIndex: outputIndex) {
                data.append(chunk)
            }
            if !output.text.isEmpty {
                data.append(responseStreamText(id: id, delta: output.text, outputIndex: outputIndex))
            }
            outputIndex += 1
        }
        for (index, toolCall) in output.toolCalls.enumerated() {
            for chunk in responseStreamToolCall(id: id, prepared: prepared, toolCall: toolCall, index: index, outputIndex: outputIndex) {
                data.append(chunk)
            }
            outputIndex += 1
        }
        for chunk in responseStreamFinish(id: id, created: created, prepared: prepared, output: output, includeMessage: includeMessage) {
            data.append(chunk)
        }
        return data
    }

    public static func responseStreamStart(id: String, created: Int, prepared: PreparedChatRequest) -> [Data] {
        let base: [String: Any] = [
            "id": id,
            "object": "response",
            "created_at": created,
            "status": "in_progress",
            "error": NSNull(),
            "incomplete_details": NSNull(),
            "model": prepared.model,
            "output": [],
            "parallel_tool_calls": true,
            "previous_response_id": (prepared.previousResponseID as Any?) ?? NSNull(),
            "reasoning": ["effort": NSNull(), "summary": NSNull()],
            "store": prepared.storeResponse,
            "tool_choice": "auto",
            "tools": [],
            "truncation": "disabled",
            "usage": NSNull(),
            "user": NSNull(),
            "metadata": [:]
        ]
        return [
            sse(["type": "response.created", "response": base], event: "response.created"),
            sse(["type": "response.in_progress", "response": base], event: "response.in_progress")
        ]
    }

    public static func responseStreamTextStart(id: String, outputIndex: Int = 0) -> [Data] {
        let messageID = "msg_\(id.dropFirst(5))"
        let item: [String: Any] = ["id": messageID, "type": "message", "status": "in_progress", "role": "assistant", "content": []]
        return [
            sse(["type": "response.output_item.added", "output_index": outputIndex, "item": item], event: "response.output_item.added"),
            sse([
                "type": "response.content_part.added",
                "item_id": messageID,
                "output_index": outputIndex,
                "content_index": 0,
                "part": ["type": "output_text", "text": "", "annotations": []]
            ], event: "response.content_part.added")
        ]
    }

    public static func responseStreamText(id: String, delta: String, outputIndex: Int = 0) -> Data {
        guard !delta.isEmpty else { return Data() }
        let messageID = "msg_\(id.dropFirst(5))"
        return sse([
            "type": "response.output_text.delta",
            "item_id": messageID,
            "output_index": outputIndex,
            "content_index": 0,
            "delta": delta
        ], event: "response.output_text.delta")
    }

    public static func responseStreamToolCall(
        id: String,
        prepared: PreparedChatRequest,
        toolCall: CursorToolCall,
        index: Int,
        outputIndex: Int
    ) -> [Data] {
        let item = responseToolCallItem(toolCall, prepared: prepared, responseID: id, index: index)
        let pending = item.merging(["arguments": "", "status": "in_progress"]) { _, new in new }
        let arguments = item["arguments"] as? String ?? "{}"
        let itemID = item["id"] as? String ?? "fc_\(index)"
        return [
            sse([
                "type": "response.output_item.added",
                "output_index": outputIndex,
                "item": pending
            ], event: "response.output_item.added"),
            sse([
                "type": "response.function_call_arguments.delta",
                "item_id": itemID,
                "output_index": outputIndex,
                "delta": arguments
            ], event: "response.function_call_arguments.delta"),
            sse([
                "type": "response.function_call_arguments.done",
                "item_id": itemID,
                "output_index": outputIndex,
                "arguments": arguments
            ], event: "response.function_call_arguments.done"),
            sse([
                "type": "response.output_item.done",
                "output_index": outputIndex,
                "item": item
            ], event: "response.output_item.done")
        ]
    }

    public static func responseStreamFinish(
        id: String,
        created: Int,
        prepared: PreparedChatRequest,
        output: CursorSDKOutput,
        includeMessage: Bool = true,
        textOutputIndex: Int = 0,
        completedResponse: [String: Any]? = nil
    ) -> [Data] {
        let messageID = "msg_\(id.dropFirst(5))"
        var chunks: [Data] = []
        if includeMessage {
            chunks.append(sse([
                "type": "response.output_text.done",
                "item_id": messageID,
                "output_index": textOutputIndex,
                "content_index": 0,
                "text": output.text
            ], event: "response.output_text.done"))
            chunks.append(sse([
                "type": "response.content_part.done",
                "item_id": messageID,
                "output_index": textOutputIndex,
                "content_index": 0,
                "part": ["type": "output_text", "text": output.text, "annotations": []]
            ], event: "response.content_part.done"))
            chunks.append(sse([
                "type": "response.output_item.done",
                "output_index": textOutputIndex,
                "item": [
                    "id": messageID,
                    "type": "message",
                    "status": "completed",
                    "role": "assistant",
                    "content": [["type": "output_text", "text": output.text, "annotations": []]]
                ]
            ], event: "response.output_item.done"))
        }
        chunks.append(sse([
            "type": "response.completed",
            "response": completedResponse ?? responseObject(id: id, created: created, prepared: prepared, output: output)
        ], event: "response.completed"))
        return chunks
    }

    public static func openAIError(_ error: any Error) -> [String: Any] {
        let cursorError = error as? CursorAPIError
        return [
            "error": [
                "message": error.localizedDescription,
                "type": "cursor_api_error",
                "code": cursorError?.code ?? "cursor_api_error"
            ]
        ]
    }

    public static func streamError(_ error: any Error) -> Data {
        sse(openAIError(error), event: "error")
    }

    private static func jsonObject(_ body: Data) throws -> [String: Any] {
        guard !body.isEmpty else { throw CursorAPIError.badRequest("Request body is required.") }
        guard let record = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw CursorAPIError.badRequest("Request body must be a JSON object.")
        }
        return record
    }

    private static func contentText(_ value: Any?, role: String) -> String {
        if let value = value as? String {
            return value
        }
        if let parts = value as? [[String: Any]] {
            return parts.compactMap { part in
                if let text = part["text"] as? String {
                    return text
                }
                if let nested = part["text"] as? [String: Any], let text = nested["value"] as? String {
                    return text
                }
                if let type = part["type"] as? String, type.contains("image") {
                    return "[image omitted]"
                }
                return nil
            }.joined(separator: "\n")
        }
        if value is NSNull || value == nil {
            return role == "assistant" ? "" : "[empty]"
        }
        return String(describing: value!)
    }

    private static func responseInputText(_ value: Any?) -> String {
        if let value = value as? String {
            return value
        }
        if let items = value as? [[String: Any]] {
            return items.compactMap { item in
                if let content = item["content"] {
                    return contentText(content, role: (item["role"] as? String) ?? "user")
                }
                if let type = item["type"] as? String, type.contains("text") {
                    return (item["text"] as? String) ?? (item["content"] as? String)
                }
                if let type = item["type"] as? String, type.contains("image") {
                    return "[image omitted]"
                }
                return nil
            }.joined(separator: "\n")
        }
        if let items = value as? [Any] {
            return items.map { responseInputText($0) }.joined(separator: "\n")
        }
        if value is NSNull || value == nil {
            return ""
        }
        return String(describing: value!)
    }

    private static func normalizedResponseInputItems(_ value: Any?) -> [JSONValue] {
        if let value = value as? String {
            return [responseInputMessage(text: value, id: "item_0")]
        }
        if let items = value as? [[String: Any]] {
            return items.enumerated().map { index, item in
                var copy = item
                if copy["id"] == nil {
                    copy["id"] = "item_\(index)"
                }
                return .object(copy.mapValues(JSONValue.from))
            }
        }
        if let items = value as? [Any] {
            return items.enumerated().map { index, item in
                if let object = item as? [String: Any] {
                    var copy = object
                    if copy["id"] == nil {
                        copy["id"] = "item_\(index)"
                    }
                    return .object(copy.mapValues(JSONValue.from))
                }
                return responseInputMessage(text: responseInputText(item), id: "item_\(index)")
            }
        }
        let text = responseInputText(value)
        return text.isEmpty ? [] : [responseInputMessage(text: text, id: "item_0")]
    }

    private static func responseInputMessage(text: String, id: String) -> JSONValue {
        .object([
            "id": .string(id),
            "type": .string("message"),
            "role": .string("user"),
            "content": .array([
                .object([
                    "type": .string("input_text"),
                    "text": .string(text)
                ])
            ])
        ])
    }

    private static func responseInputItemID(_ item: JSONValue) -> String? {
        item.objectValue?["id"]?.stringValue
    }

    @discardableResult
    private static func appendResponsesInput(
        _ value: Any?,
        to transcript: inout [String],
        remembered: inout [String: (name: String, arguments: [String: Any])]
    ) -> Bool {
        if let value = value as? String {
            transcript.append(value.isEmpty ? "[empty]" : value)
            return true
        }
        if let items = value as? [[String: Any]] {
            var appended = false
            for item in items {
                let type = (item["type"] as? String) ?? ""
                if type == "function_call" {
                    appended = true
                    let callID = (item["call_id"] as? String) ?? (item["id"] as? String) ?? ""
                    let name = (item["name"] as? String) ?? ""
                    let arguments = (item["arguments"] as? String) ?? "{}"
                    let parsedArguments = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] ?? [:]
                    if !callID.isEmpty {
                        remembered[callID] = (name: name, arguments: parsedArguments)
                    }
                    transcript.append("ASSISTANT FUNCTION_CALL: \(jsonString(["call_id": callID, "name": name, "arguments": arguments]))")
                    continue
                }
                if type == "function_call_output" {
                    appended = true
                    let callID = (item["call_id"] as? String) ?? ""
                    let output = responseInputText(item["output"] ?? item["content"])
                    let rememberedCall = remembered[callID]
                    let toolName = rememberedCall?.name ?? ""
                    let label = [toolName.isEmpty ? nil : "name=\(toolName)", callID.isEmpty ? nil : "call_id=\(callID)"]
                        .compactMap { $0 }
                        .joined(separator: " ")
                    transcript.append("FUNCTION CALL OUTPUT\(label.isEmpty ? "" : " (\(label))"): \(output.isEmpty ? "[empty]" : output)")
                    transcript.append("LOCAL TOOL RESULT: \(toolResultFeedback(toolCallID: callID, toolName: toolName, text: output, remembered: remembered))")
                    continue
                }
                let role = (item["role"] as? String) ?? (type == "message" ? "assistant" : "user")
                let text = item["content"].map { contentText($0, role: role) } ?? responseInputText(item)
                if !text.isEmpty {
                    appended = true
                    transcript.append("\(role.uppercased()): \(text)")
                }
            }
            return appended
        }
        if let items = value as? [Any] {
            var appended = false
            for item in items {
                appended = appendResponsesInput(item, to: &transcript, remembered: &remembered) || appended
            }
            return appended
        }
        let text = responseInputText(value)
        if !text.isEmpty {
            transcript.append(text)
            return true
        }
        return false
    }

    private static func parseTools(_ value: Any?, disabled: Bool) -> [OpenAIToolSpec] {
        guard !disabled, let tools = value as? [[String: Any]] else { return [] }
        return tools.compactMap { tool in
            guard (tool["type"] as? String) == "function" else {
                return nil
            }
            let function = tool["function"] as? [String: Any] ?? tool
            guard let name = function["name"] as? String,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let parameters = function["parameters"].map(JSONValue.from)
            return OpenAIToolSpec(name: name, description: function["description"] as? String, parameters: parameters)
        }
    }

    private static func appendToolInventory(_ transcript: inout [String], tools: [OpenAIToolSpec], toolChoice: Any?) {
        guard !tools.isEmpty else { return }
        transcript.append("")
        transcript.append("LOCAL TOOL INVENTORY:")
        transcript.append("Allowed tool names: \(tools.map(\.name).joined(separator: ", "))")
        transcript.append("Use only the client's local tools for filesystem and shell work.")
        for tool in tools {
            var record: [String: Any] = ["name": tool.name]
            if let description = tool.description { record["description"] = description }
            if let parameters = tool.parameters { record["parameters"] = parameters.foundationValue }
            if let data = try? JSONSerialization.data(withJSONObject: record, options: [.withoutEscapingSlashes]),
               let json = String(data: data, encoding: .utf8) {
                transcript.append(json)
            }
        }
        if let choice = toolChoice as? [String: Any],
           let function = choice["function"] as? [String: Any],
           let name = function["name"] as? String {
            transcript.append("Use the \(name) tool if you call a tool.")
        } else if (toolChoice as? String) == "required" {
            transcript.append("You must call at least one tool.")
        }
    }

    private static func appendOptions(_ transcript: inout [String], _ raw: [String: Any]) {
        var options: [String] = []
        for key in ["temperature", "top_p", "max_tokens", "max_completion_tokens"] {
            if let value = raw[key] {
                options.append("\(key): \(value)")
            }
        }
        guard !options.isEmpty else { return }
        transcript.append("")
        transcript.append("REQUEST OPTIONS:")
        transcript.append(options.joined(separator: "\n"))
    }

    private static func responseSessionHint(_ raw: [String: Any]) -> String? {
        if let value = firstStringValue(in: raw, keys: ["session_id", "conversation_id", "thread_id"]) {
            return "request:\(value)"
        }
        if let metadata = raw["metadata"] as? [String: Any] {
            if let value = firstStringValue(in: metadata, keys: ["session_id", "conversation_id", "thread_id"]) {
                return "metadata-session:\(value)"
            }
            if let value = firstStringValue(in: metadata, keys: ["project_path", "workspace_path", "working_directory", "cwd", "project_id", "project", "workspace"]) {
                return "metadata-project:\(value)"
            }
        }
        if let user = stringValue(raw["user"]) {
            return "user:\(user)"
        }
        return nil
    }

    private static func firstStringValue(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = stringValue(object[key]) {
                return value
            }
        }
        return nil
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String {
            return value.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        }
        if let value = value as? NSNumber {
            return value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        }
        return nil
    }

    private static func rememberToolCalls(_ toolCalls: [[String: Any]], into remembered: inout [String: (name: String, arguments: [String: Any])]) {
        for toolCall in toolCalls {
            guard let id = toolCall["id"] as? String,
                  let function = toolCall["function"] as? [String: Any],
                  let name = function["name"] as? String else {
                continue
            }
            let argsString = function["arguments"] as? String ?? "{}"
            let argsData = Data(argsString.utf8)
            let args = (try? JSONSerialization.jsonObject(with: argsData)) as? [String: Any] ?? [:]
            remembered[id] = (name: name, arguments: args)
        }
    }

    private static func toolResultFeedback(
        toolCallID: String,
        toolName: String,
        text: String,
        remembered: [String: (name: String, arguments: [String: Any])]
    ) -> String {
        let rememberedCall = remembered[toolCallID]
        let record: [String: Any] = [
            "toolCallId": toolCallID,
            "toolName": toolName.isEmpty ? rememberedCall?.name ?? "" : toolName,
            "arguments": rememberedCall?.arguments ?? [:],
            "result": text
        ]
        let data = (try? JSONSerialization.data(withJSONObject: record, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func toOpenAIToolCalls(_ toolCalls: [CursorToolCall], tools: [OpenAIToolSpec], responseID: String) -> [[String: Any]] {
        toolCalls.enumerated().map { index, toolCall in
            let resolved = resolveToolCall(toolCall, tools: tools)
            return [
                "id": "call_\(responseID.replacingOccurrences(of: "[^A-Za-z0-9]", with: "", options: .regularExpression).suffix(18))_\(index)",
                "type": "function",
                "function": [
                    "name": resolved.name,
                    "arguments": jsonString(resolved.arguments.mapValues(\.foundationValue))
                ]
            ]
        }
    }

    private static func responseToolCallItems(_ toolCalls: [CursorToolCall], prepared: PreparedChatRequest, responseID: String) -> [[String: Any]] {
        toolCalls.enumerated().map { index, toolCall in
            responseToolCallItem(toolCall, prepared: prepared, responseID: responseID, index: index)
        }
    }

    private static func responseToolCallItem(_ toolCall: CursorToolCall, prepared: PreparedChatRequest, responseID: String, index: Int) -> [String: Any] {
        let resolved = resolveToolCall(toolCall, tools: prepared.tools)
        let suffix = responseID.replacingOccurrences(of: "[^A-Za-z0-9]", with: "", options: .regularExpression).suffix(18)
        return [
            "id": "fc_\(suffix)_\(index)",
            "type": "function_call",
            "call_id": "call_\(suffix)_\(index)",
            "name": resolved.name,
            "arguments": jsonString(resolved.arguments.mapValues(\.foundationValue)),
            "status": "completed"
        ]
    }

    private struct ResolvedToolCall {
        var name: String
        var arguments: [String: JSONValue]
    }

    private static func resolveToolCall(_ toolCall: CursorToolCall, tools: [OpenAIToolSpec]) -> ResolvedToolCall {
        guard let tool = resolveToolSpec(toolCall.name, tools: tools) else {
            return ResolvedToolCall(name: toolCall.name, arguments: toolCall.arguments)
        }
        return ResolvedToolCall(
            name: tool.name,
            arguments: normalizeArguments(toolCall.arguments, sdkToolName: toolCall.name, tool: tool)
        )
    }

    private static func resolveToolSpec(_ name: String, tools: [OpenAIToolSpec]) -> OpenAIToolSpec? {
        if let exact = tools.first(where: { $0.name == name }) { return exact }
        let normalized = normalizedName(name)
        if let caseInsensitive = tools.first(where: { normalizedName($0.name) == normalized }) {
            return caseInsensitive
        }

        let aliases = Set(toolAliases(for: name).map(normalizedName))
        if let aliased = tools.first(where: { aliases.contains(normalizedName($0.name)) }) {
            return aliased
        }

        return tools.first { schemaLooksCompatible(sdkToolName: name, tool: $0) }
    }

    private static func normalizeArguments(
        _ arguments: [String: JSONValue],
        sdkToolName: String,
        tool: OpenAIToolSpec
    ) -> [String: JSONValue] {
        let properties = parameterPropertyNames(tool)
        let selectedTool = normalizedName(tool.name)
        let canonical = canonicalToolName(sdkToolName)

        if selectedTool == "strreplaceeditor", canonical == "write" {
            return strReplaceEditorArguments(arguments, properties: properties)
        }

        guard !properties.isEmpty else { return arguments }

        var output: [String: JSONValue] = [:]
        var consumed = Set<String>()

        func copy(_ source: String, as candidates: [String]) {
            guard let value = arguments[source] else { return }
            guard let target = propertyName(matching: [source] + candidates, in: properties) else {
                consumed.insert(source)
                return
            }
            output[target] = value
            consumed.insert(source)
        }

        switch canonical {
        case "shell":
            copy("command", as: ["cmd", "script", "input"])
            copy("workingDirectory", as: ["cwd", "workdir", "working_directory", "directory"])
            copy("timeout", as: ["timeoutMs", "timeout_ms", "timeoutSeconds", "timeout_seconds"])
        case "write":
            copy("path", as: pathPropertyAliases())
            copy("fileText", as: ["file_text", "content", "contents", "text", "fileContent", "file_content"])
            copy("returnFileContentAfterWrite", as: ["returnFileContent", "return_file_content", "return_file_content_after_write"])
        case "read", "delete":
            copy("path", as: pathPropertyAliases())
            copy("offset", as: ["start", "startLine", "start_line"])
            copy("limit", as: ["maxLines", "max_lines", "lineCount", "line_count"])
            copy("includeLineNumbers", as: ["include_line_numbers", "lineNumbers", "line_numbers"])
        case "grep":
            copy("pattern", as: ["query", "regex", "search"])
            copy("path", as: pathPropertyAliases() + ["directory"])
            copy("glob", as: ["include", "includeGlob", "include_glob"])
            copy("outputMode", as: ["output_mode", "mode"])
            copy("contextBefore", as: ["context_before", "beforeContext", "before_context"])
            copy("contextAfter", as: ["context_after", "afterContext", "after_context"])
            copy("context", as: ["contextLines", "context_lines"])
            copy("caseInsensitive", as: ["case_insensitive", "ignoreCase", "ignore_case"])
            copy("headLimit", as: ["head_limit", "limit", "maxResults", "max_results"])
            copy("multiline", as: ["multiLine", "multi_line"])
            copy("sort", as: ["sortBy", "sort_by"])
            copy("sortAscending", as: ["sort_ascending", "ascending"])
            copy("offset", as: ["start", "startLine", "start_line"])
        case "glob":
            copy("targetDirectory", as: ["target_directory", "directory", "cwd", "path"])
            copy("globPattern", as: ["glob_pattern", "pattern", "glob"])
        case "ls":
            copy("path", as: pathPropertyAliases() + ["directory", "dir"])
            copy("ignore", as: ["ignorePatterns", "ignore_patterns", "exclude"])
        case "readlints":
            copy("paths", as: ["files", "filePaths", "file_paths"])
        case "mcp":
            copy("providerIdentifier", as: ["provider", "server", "serverName", "server_name"])
            copy("toolName", as: ["tool", "name", "tool_name"])
        case "semsearch":
            copy("query", as: ["pattern", "search"])
            copy("targetDirectories", as: ["target_directories", "directories", "paths"])
            copy("explanation", as: ["reason", "why"])
        default:
            break
        }

        for (key, value) in arguments where !consumed.contains(key) {
            if let target = propertyName(matching: [key], in: properties) {
                output[target] = value
            }
        }

        return output.isEmpty ? arguments : output
    }

    private static func strReplaceEditorArguments(_ arguments: [String: JSONValue], properties: [String]) -> [String: JSONValue] {
        let fallbackProperties = properties.isEmpty ? ["command", "path", "file_text"] : properties
        var output: [String: JSONValue] = [:]
        if let commandKey = propertyName(matching: ["command"], in: fallbackProperties) {
            output[commandKey] = .string("create")
        }
        if let path = arguments["path"],
           let pathKey = propertyName(matching: pathPropertyAliases(), in: fallbackProperties) {
            output[pathKey] = path
        }
        if let fileText = arguments["fileText"],
           let contentKey = propertyName(matching: ["file_text", "fileText", "content", "contents", "text"], in: fallbackProperties) {
            output[contentKey] = fileText
        }
        return output.isEmpty ? arguments : output
    }

    private static func schemaLooksCompatible(sdkToolName: String, tool: OpenAIToolSpec) -> Bool {
        let properties = parameterPropertyNames(tool)
        guard !properties.isEmpty else { return false }
        func has(_ candidates: [String]) -> Bool {
            propertyName(matching: candidates, in: properties) != nil
        }
        switch canonicalToolName(sdkToolName) {
        case "shell":
            return has(["command", "cmd", "script"])
        case "write":
            return has(pathPropertyAliases()) && has(["fileText", "file_text", "content", "contents", "text"])
        case "read", "delete":
            return has(pathPropertyAliases())
        case "grep":
            return has(["pattern", "query", "regex"])
        case "glob":
            return has(["globPattern", "glob_pattern", "pattern", "glob"])
        case "ls":
            return has(pathPropertyAliases() + ["directory", "dir"])
        case "readlints":
            return has(["paths", "files", "filePaths", "file_paths"])
        case "mcp":
            return has(["toolName", "tool_name", "tool", "name"])
        case "semsearch":
            return has(["query", "pattern", "search"])
        default:
            return false
        }
    }

    private static func parameterPropertyNames(_ tool: OpenAIToolSpec) -> [String] {
        guard case .object(let root)? = tool.parameters,
              case .object(let properties)? = root["properties"] else {
            return []
        }
        return Array(properties.keys)
    }

    private static func propertyName(matching candidates: [String], in properties: [String]) -> String? {
        for candidate in candidates {
            if properties.contains(candidate) {
                return candidate
            }
        }
        let normalizedCandidates = Set(candidates.map(normalizedName))
        return properties.first { normalizedCandidates.contains(normalizedName($0)) }
    }

    private static func canonicalToolName(_ name: String) -> String {
        let normalized = normalizedName(name)
        switch normalized {
        case "bash", "runshellcommand", "runterminalcommand", "terminal", "execute", "executecommand", "runcommand", "run":
            return "shell"
        case "writefile", "createfile", "editfile", "replacefile", "strreplaceeditor":
            return "write"
        case "readfile", "openfile", "viewfile":
            return "read"
        case "deletefile", "removefile":
            return "delete"
        case "search", "searchfiles", "searchfilesystem", "ripgrep", "rg":
            return "grep"
        case "globfiles", "findfiles":
            return "glob"
        case "list", "listfiles", "listdirectory", "listdir":
            return "ls"
        case "readlints", "diagnostics", "getdiagnostics":
            return "readlints"
        case "semanticsearch", "semsearch", "searchcode":
            return "semsearch"
        case "callmcptool":
            return "mcp"
        default:
            return normalized
        }
    }

    private static func toolAliases(for name: String) -> [String] {
        switch canonicalToolName(name) {
        case "shell":
            return ["shell", "bash", "run_shell_command", "run_terminal_command", "terminal", "execute", "execute_command", "run_command", "run"]
        case "write":
            return ["write", "write_file", "create_file", "edit_file", "replace_file", "str_replace_editor"]
        case "read":
            return ["read", "read_file", "open_file", "view_file"]
        case "delete":
            return ["delete", "delete_file", "remove_file"]
        case "grep":
            return ["grep", "search", "search_files", "search_filesystem", "ripgrep", "rg"]
        case "glob":
            return ["glob", "glob_files", "find_files"]
        case "ls":
            return ["ls", "list", "list_files", "list_directory", "list_dir"]
        case "readlints":
            return ["read_lints", "readLints", "diagnostics", "get_diagnostics"]
        case "mcp":
            return ["mcp", "call_mcp_tool"]
        case "semsearch":
            return ["sem_search", "semantic_search", "search_code"]
        default:
            return [name]
        }
    }

    private static func pathPropertyAliases() -> [String] {
        ["path", "file_path", "filePath", "filename", "file"]
    }

    private static func normalizedName(_ value: String) -> String {
        value.lowercased().replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
    }

    private static func usage(promptCharacters: Int, completionCharacters: Int) -> [String: Any] {
        let promptTokens = max(1, Int(ceil(Double(promptCharacters) / 4.0)))
        let completionTokens = max(0, Int(ceil(Double(completionCharacters) / 4.0)))
        return [
            "prompt_tokens": promptTokens,
            "completion_tokens": completionTokens,
            "total_tokens": promptTokens + completionTokens
        ]
    }

    private static func serializedLength(_ value: Any) -> Int {
        (try? JSONSerialization.data(withJSONObject: value)).map(\.count) ?? 0
    }

    private static func jsonString(_ value: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func sse(_ value: Any, event: String? = nil) -> Data {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        let prefix = event.map { "event: \($0)\n" } ?? ""
        return Data("\(prefix)data: \(json)\n\n".utf8)
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}

private func + (lhs: [String: Any], rhs: [String: Any]) -> [String: Any] {
    var copy = lhs
    for (key, value) in rhs {
        copy[key] = value
    }
    return copy
}
