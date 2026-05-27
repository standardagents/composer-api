import Foundation

public struct OpenAIToolSpec: Codable, Equatable, Sendable {
    public var name: String
    public var description: String?
    public var parameters: JSONValue?
}

public struct ResponseToolCallMemory: Equatable, Sendable {
    public var name: String
    public var arguments: [String: JSONValue]

    public init(name: String, arguments: [String: JSONValue]) {
        self.name = name
        self.arguments = arguments
    }
}

public struct PreparedChatRequest: Equatable, Sendable {
    public var model: String
    public var cursorModelID: String
    public var prompt: String
    public var stream: Bool
    public var streamIncludeUsage: Bool
    public var promptCharacters: Int
    public var tools: [OpenAIToolSpec]
    public var sessionKey: String?
    public var requestedSessionKey: String?
    public var previousResponseID: String?
    public var storeResponse: Bool
    public var responseInputItems: [JSONValue]
}

public enum OpenAICompatibility {
    private static let toolResultContinuation = "The above tool calls have been executed. Continue your response based on these results."

    public static func modelList() -> [String: Any] {
        [
            "object": "list",
            "data": ComposerModels.all.map(modelObject),
            "models": ComposerModels.all.map(codexModelObject)
        ]
    }

    public static func modelObject(_ model: ComposerModel) -> [String: Any] {
        [
            "id": model.id,
            "object": "model",
            "created": 1_779_148_800,
            "owned_by": "cursor",
            "name": model.name,
            "cost": [
                "input": model.inputCost,
                "output": model.outputCost
            ],
            "limit": [
                "context": model.contextWindow,
                "output": model.outputLimit
            ]
        ]
    }

    public static func codexModelObject(_ model: ComposerModel) -> [String: Any] {
        [
            "slug": model.id,
            "display_name": model.name,
            "description": "Local Composer model served by \(CursorAPIBrand.displayName).",
            "default_reasoning_level": NSNull(),
            "supported_reasoning_levels": [],
            "shell_type": "shell_command",
            "visibility": "list",
            "supported_in_api": true,
            "priority": model.id == "composer-2.5" ? 10 : 9,
            "additional_speed_tiers": [],
            "service_tiers": [],
            "default_service_tier": NSNull(),
            "availability_nux": NSNull(),
            "upgrade": NSNull(),
            "base_instructions": "",
            "model_messages": NSNull(),
            "supports_reasoning_summaries": false,
            "default_reasoning_summary": "auto",
            "support_verbosity": false,
            "default_verbosity": NSNull(),
            "apply_patch_tool_type": NSNull(),
            "web_search_tool_type": "text",
            "truncation_policy": [
                "mode": "tokens",
                "limit": model.contextWindow
            ],
            "supports_parallel_tool_calls": true,
            "supports_image_detail_original": false,
            "context_window": model.contextWindow,
            "max_context_window": model.contextWindow,
            "auto_compact_token_limit": Int(Double(model.contextWindow) * 0.9),
            "effective_context_window_percent": 90,
            "experimental_supported_tools": [],
            "input_modalities": ["text"],
            "supports_search_tool": false
        ]
    }

    public static func prepareChatRequest(_ body: Data) throws -> PreparedChatRequest {
        let raw = try jsonObject(body)
        guard let messages = raw["messages"] as? [[String: Any]] else {
            throw CursorAPIError.badRequest("messages must be an array.")
        }
        let tools = parseTools(raw["tools"], disabled: (raw["tool_choice"] as? String) == "none")
        let model = try ComposerModels.resolvedModelID(for: raw["model"] as? String)
        var transcript = [
            "You are running through a local Cursor SDK-compatible harness.",
            "The client owns local tool execution. When local inspection, shell commands, or file changes are needed, request a tool call and wait for the tool result.",
            "When the conversation includes LOCAL TOOL RESULT records, treat them as completed SDK tool_call results for your previous tool requests and continue from those results.",
            "If the user explicitly names an allowed client tool, use that tool. OpenCode MCP/server tools exposed as provider_tool names are called through SDK mcp with providerIdentifier, toolName, and args.",
            "For general file creation when no specific client tool is requested, prefer SDK shell when a shell client tool is available; otherwise request write calls with both path and fileText.",
            "Do not claim that you created, edited, inspected, or ran anything locally unless you emitted a tool call and received a LOCAL TOOL RESULT confirming it.",
            "When starting a dev server or other long-running watcher, start it in the background with output redirected and return immediately.",
            "Do not say that agent mode or tools are unavailable."
        ]
        appendToolInventory(&transcript, tools: tools, toolChoice: raw["tool_choice"])
        transcript.append("")
        transcript.append("Conversation:")
        var rememberedToolCalls: [String: ResponseToolCallMemory] = [:]
        var sawToolResult = false
        var latestUserText = ""

        for item in messages {
            let role = (item["role"] as? String) ?? "user"
            let text = contentText(item["content"], role: role)
            if role == "tool" {
                sawToolResult = true
                let toolCallID = (item["tool_call_id"] as? String) ?? ""
                let toolName = (item["name"] as? String) ?? rememberedToolCalls[toolCallID]?.name ?? ""
                let label = [toolName.isEmpty ? nil : "name=\(toolName)", toolCallID.isEmpty ? nil : "tool_call_id=\(toolCallID)"]
                    .compactMap { $0 }
                    .joined(separator: " ")
                transcript.append("TOOL RESULT\(label.isEmpty ? "" : " (\(label))"): \(text.isEmpty ? "[empty]" : text)")
                transcript.append("LOCAL TOOL RESULT: \(toolResultFeedback(toolCallID: toolCallID, toolName: toolName, text: text, remembered: rememberedToolCalls))")
            } else {
                transcript.append("\(role.uppercased()): \(text.isEmpty ? "[empty]" : text)")
                if role == "user", !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    latestUserText = text
                }
            }

            if let toolCalls = item["tool_calls"] as? [[String: Any]] {
                appendToolCallTranscript(&transcript, role: role, toolCalls: toolCalls)
                rememberToolCalls(toolCalls, into: &rememberedToolCalls)
            }
        }
        if sawToolResult {
            transcript.append("")
            transcript.append(toolResultContinuation)
        }
        if shouldRequireLocalTool(for: latestUserText, tools: tools) {
            appendRequiredLocalToolHint(&transcript, tools: tools, latestUserText: latestUserText)
        }
        appendOptions(&transcript, raw)
        let prompt = transcript.joined(separator: "\n")
        return PreparedChatRequest(
            model: model,
            cursorModelID: model,
            prompt: prompt,
            stream: raw["stream"] as? Bool == true,
            streamIncludeUsage: streamIncludeUsage(raw),
            promptCharacters: prompt.count,
            tools: tools,
            sessionKey: nil,
            requestedSessionKey: nil,
            previousResponseID: nil,
            storeResponse: false,
            responseInputItems: []
        )
    }

    public static func prepareCompletionRequest(_ body: Data) throws -> PreparedChatRequest {
        let raw = try jsonObject(body)
        guard let prompt = raw["prompt"] else {
            throw CursorAPIError.badRequest("prompt is required.")
        }
        let model = try ComposerModels.resolvedModelID(for: raw["model"] as? String)
        var transcript = [
            "You are running through a local Cursor SDK-compatible harness.",
            "Respond to the following legacy completions prompt as plain assistant text.",
            "When starting a dev server or other long-running watcher, start it in the background with output redirected and return immediately.",
            "",
            "PROMPT:",
            completionPromptText(prompt)
        ]
        appendOptions(&transcript, raw)
        let joined = transcript.joined(separator: "\n")
        return PreparedChatRequest(
            model: model,
            cursorModelID: model,
            prompt: joined,
            stream: raw["stream"] as? Bool == true,
            streamIncludeUsage: streamIncludeUsage(raw),
            promptCharacters: joined.count,
            tools: [],
            sessionKey: nil,
            requestedSessionKey: nil,
            previousResponseID: nil,
            storeResponse: false,
            responseInputItems: []
        )
    }

    public static func prepareResponsesRequest(_ body: Data) throws -> PreparedChatRequest {
        try prepareResponsesRequest(body, rememberedToolCalls: [:])
    }

    public static func prepareResponseCompactionRequest(_ body: Data) throws -> PreparedChatRequest {
        let raw = try jsonObject(body)
        let model = try ComposerModels.resolvedModelID(for: raw["model"] as? String)
        let instructions = (raw["instructions"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        var transcript = [
            "You are compacting a long-running local Responses API conversation.",
            "Return a concise continuation summary that preserves user goals, decisions, constraints, important file paths, pending tasks, tool results, and any unresolved errors.",
            "Do not add new actions or answer the original request; only summarize the conversation state for a future model turn."
        ]
        if let instructions, !instructions.isEmpty {
            transcript.append("")
            transcript.append("COMPACTION INSTRUCTIONS:")
            transcript.append(instructions)
        }
        transcript.append("")
        transcript.append("CONVERSATION TO COMPACT:")
        var rememberedToolCalls: [String: ResponseToolCallMemory] = [:]
        let appendedInput = appendResponsesInput(raw["input"], to: &transcript, remembered: &rememberedToolCalls)
        if !appendedInput.appended {
            transcript.append("[empty]")
        }
        appendOptions(&transcript, raw)
        let prompt = transcript.joined(separator: "\n")
        return PreparedChatRequest(
            model: model,
            cursorModelID: model,
            prompt: prompt,
            stream: false,
            streamIncludeUsage: false,
            promptCharacters: prompt.count,
            tools: [],
            sessionKey: nil,
            requestedSessionKey: responseSessionHint(raw),
            previousResponseID: nil,
            storeResponse: false,
            responseInputItems: normalizedResponseInputItems(raw["input"])
        )
    }

    static func prepareResponsesRequest(_ body: Data, rememberedToolCalls: [String: ResponseToolCallMemory]) throws -> PreparedChatRequest {
        let raw = try jsonObject(body)
        let model = try ComposerModels.resolvedModelID(for: raw["model"] as? String)
        let instructions = (raw["instructions"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let tools = parseTools(raw["tools"], disabled: (raw["tool_choice"] as? String) == "none")
        let previousResponseID = (raw["previous_response_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        var transcript = [
            "You are running through a local Cursor SDK-compatible harness.",
            "The client owns local tool execution. When local inspection, shell commands, or file changes are needed, request a function_call and wait for the function_call_output.",
            "When the input includes function_call_output records, treat them as completed local tool results for your previous function_call requests and continue from those results.",
            "If the user explicitly names an allowed client tool, use that tool. OpenCode MCP/server tools exposed as provider_tool names are called through SDK mcp with providerIdentifier, toolName, and args.",
            "For general file creation when no specific client tool is requested, prefer SDK shell when a shell client tool is available; otherwise request write calls with both path and fileText.",
            "Do not claim that you created, edited, inspected, or ran anything locally unless you emitted a function_call and received a function_call_output confirming it.",
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
        var rememberedToolCalls = rememberedToolCalls
        let input = raw["input"]
        let appendedInput = appendResponsesInput(input, to: &transcript, remembered: &rememberedToolCalls)
        if !appendedInput.appended {
            transcript.append("[empty]")
        }
        if appendedInput.sawToolOutput {
            transcript.append("")
            transcript.append(toolResultContinuation)
        }
        if shouldRequireLocalTool(for: latestUserText(from: input), tools: tools) {
            appendRequiredLocalToolHint(&transcript, tools: tools, latestUserText: latestUserText(from: input))
        }
        appendOptions(&transcript, raw)
        let prompt = transcript.joined(separator: "\n")
        return PreparedChatRequest(
            model: model,
            cursorModelID: model,
            prompt: prompt,
            stream: raw["stream"] as? Bool == true,
            streamIncludeUsage: streamIncludeUsage(raw),
            promptCharacters: prompt.count,
            tools: tools,
            sessionKey: nil,
            requestedSessionKey: responseSessionHint(raw),
            previousResponseID: previousResponseID,
            storeResponse: raw["store"] as? Bool ?? true,
            responseInputItems: normalizedResponseInputItems(input)
        )
    }

    public static func responseToolCallMemory(
        id: String,
        prepared: PreparedChatRequest,
        output: CursorSDKOutput
    ) -> [String: ResponseToolCallMemory] {
        let suffix = id.replacingOccurrences(of: "[^A-Za-z0-9]", with: "", options: .regularExpression).suffix(18)
        return Dictionary(uniqueKeysWithValues: output.toolCalls.enumerated().compactMap { index, toolCall in
            guard let resolved = resolveToolCall(toolCall, tools: prepared.tools) else {
                return nil
            }
            return (
                "call_\(suffix)_\(index)",
                ResponseToolCallMemory(name: resolved.name, arguments: resolved.arguments)
            )
        })
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

    public static func responseInputTokenCountObject(_ body: Data) throws -> [String: Any] {
        let prepared = try prepareResponsesRequest(body)
        return [
            "object": "response.input_tokens",
            "input_tokens": inputTokenEstimate(characters: prepared.promptCharacters)
        ]
    }

    public static func responseCompactionObject(
        id: String,
        created: Int,
        prepared: PreparedChatRequest,
        output: CursorSDKOutput
    ) -> [String: Any] {
        let compactionID = "cmp_\(id.dropFirst(5))"
        let summary = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            "id": id,
            "object": "response.compaction",
            "created_at": created,
            "output": [
                [
                    "id": compactionID,
                    "type": "compaction",
                    "encrypted_content": summary.isEmpty ? "[empty conversation summary]" : summary
                ]
            ],
            "usage": usage(promptCharacters: prepared.promptCharacters, completionCharacters: output.text.count),
            "cursor_agent_id": output.agentID,
            "cursor_run_id": output.runID
        ]
    }

    public static func chatCompletionResponse(
        id: String,
        created: Int,
        prepared: PreparedChatRequest,
        output: CursorSDKOutput
    ) -> [String: Any] {
        let toolCalls = toOpenAIToolCalls(output.toolCalls, tools: prepared.tools, responseID: id)
        let content: Any = toolCalls.isEmpty ? output.text : NSNull()
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

    public static func completionResponse(
        id: String,
        created: Int,
        prepared: PreparedChatRequest,
        output: CursorSDKOutput
    ) -> [String: Any] {
        [
            "id": id,
            "object": "text_completion",
            "created": created,
            "model": prepared.model,
            "choices": [
                [
                    "text": output.text,
                    "index": 0,
                    "logprobs": NSNull(),
                    "finish_reason": "stop"
                ]
            ],
            "usage": usage(promptCharacters: prepared.promptCharacters, completionCharacters: output.text.count),
            "cursor_agent_id": output.agentID,
            "cursor_run_id": output.runID
        ]
    }

    public static func completionStreamText(id: String, created: Int, model: String, text: String) -> Data {
        guard !text.isEmpty else { return Data() }
        return sse([
            "id": id,
            "object": "text_completion",
            "created": created,
            "model": model,
            "choices": [["text": text, "index": 0, "logprobs": NSNull(), "finish_reason": NSNull()]]
        ])
    }

    public static func completionStreamFinish(id: String, created: Int, model: String) -> Data {
        sse([
            "id": id,
            "object": "text_completion",
            "created": created,
            "model": model,
            "choices": [["text": "", "index": 0, "logprobs": NSNull(), "finish_reason": "stop"]]
        ])
    }

    public static func completionStreamDone() -> Data {
        Data("data: [DONE]\n\n".utf8)
    }

    public static func chatCompletionStream(
        id: String,
        created: Int,
        prepared: PreparedChatRequest,
        output: CursorSDKOutput
    ) throws -> Data {
        var data = Data()
        data.append(chatCompletionStreamStart(id: id, created: created, model: prepared.model))
        var emittedToolCallCount = 0
        for toolCall in output.toolCalls {
            let chunk = chatCompletionStreamToolCall(id: id, created: created, prepared: prepared, toolCall: toolCall, index: emittedToolCallCount)
            guard !chunk.isEmpty else { continue }
            data.append(chunk)
            emittedToolCallCount += 1
        }
        if emittedToolCallCount == 0, !output.text.isEmpty {
            data.append(chatCompletionStreamText(id: id, created: created, model: prepared.model, delta: output.text))
        }
        data.append(chatCompletionStreamFinish(id: id, created: created, model: prepared.model, emittedToolCallCount: emittedToolCallCount))
        if prepared.streamIncludeUsage {
            data.append(chatCompletionStreamUsage(id: id, created: created, prepared: prepared, output: output))
        }
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
        guard let converted = toOpenAIToolCalls([toolCall], tools: prepared.tools, responseID: "\(id)_\(index)").first else {
            return Data()
        }
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

    public static func chatCompletionStreamUsage(id: String, created: Int, prepared: PreparedChatRequest, output: CursorSDKOutput) -> Data {
        let toolCalls = toOpenAIToolCalls(output.toolCalls, tools: prepared.tools, responseID: id)
        return sse([
            "id": id,
            "object": "chat.completion.chunk",
            "created": created,
            "model": prepared.model,
            "system_fingerprint": NSNull(),
            "choices": [],
            "usage": usage(promptCharacters: prepared.promptCharacters, completionCharacters: output.text.count + serializedLength(toolCalls))
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
        if toolCallItems.isEmpty {
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
            "usage": responsesUsage(promptCharacters: prepared.promptCharacters, outputCharacters: output.text.count + serializedLength(toolCallItems)),
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
        let toolCallItems = responseToolCallItems(output.toolCalls, prepared: prepared, responseID: id)
        let includeMessage = toolCallItems.isEmpty
        if includeMessage {
            for chunk in responseStreamTextStart(id: id, outputIndex: outputIndex) {
                data.append(chunk)
            }
            if !output.text.isEmpty {
                data.append(responseStreamText(id: id, delta: output.text, outputIndex: outputIndex))
            }
            outputIndex += 1
        }
        for item in toolCallItems {
            for chunk in responseStreamToolCallItem(item, outputIndex: outputIndex) {
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
        guard let item = responseToolCallItem(toolCall, prepared: prepared, responseID: id, index: index) else {
            return []
        }
        return responseStreamToolCallItem(item, outputIndex: outputIndex)
    }

    private static func responseStreamToolCallItem(_ item: [String: Any], outputIndex: Int) -> [Data] {
        let pending = item.merging(["arguments": "", "status": "in_progress"]) { _, new in new }
        let arguments = item["arguments"] as? String ?? "{}"
        let itemID = item["id"] as? String ?? "fc_\(outputIndex)"
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

    private static func streamIncludeUsage(_ raw: [String: Any]) -> Bool {
        guard let options = raw["stream_options"] as? [String: Any] else {
            return false
        }
        return options["include_usage"] as? Bool == true
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

    private static func completionPromptText(_ value: Any) -> String {
        if let value = value as? String {
            return value
        }
        if let prompts = value as? [String] {
            return prompts.joined(separator: "\n\n")
        }
        if let prompts = value as? [Any] {
            return prompts.map { completionPromptText($0) }.joined(separator: "\n\n")
        }
        if value is NSNull {
            return "[empty]"
        }
        return String(describing: value)
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

    private static func latestUserText(from value: Any?) -> String {
        if let value = value as? String {
            return value
        }
        if let items = value as? [[String: Any]] {
            for item in items.reversed() {
                let type = (item["type"] as? String) ?? ""
                let role = (item["role"] as? String) ?? (type == "message" ? "user" : "")
                guard role == "user" || type == "input_text" else { continue }
                if let content = item["content"] {
                    let text = contentText(content, role: role.isEmpty ? "user" : role)
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return text
                    }
                }
                if let text = item["text"] as? String,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return text
                }
            }
            return ""
        }
        if let items = value as? [Any] {
            for item in items.reversed() {
                let text = latestUserText(from: item)
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return text
                }
            }
            return ""
        }
        return ""
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

    private struct ResponsesInputAppendResult {
        var appended: Bool
        var sawToolOutput: Bool
    }

    @discardableResult
    private static func appendResponsesInput(
        _ value: Any?,
        to transcript: inout [String],
        remembered: inout [String: ResponseToolCallMemory]
    ) -> ResponsesInputAppendResult {
        if let value = value as? String {
            transcript.append(value.isEmpty ? "[empty]" : value)
            return ResponsesInputAppendResult(appended: true, sawToolOutput: false)
        }
        if let items = value as? [[String: Any]] {
            var appended = false
            var sawToolOutput = false
            for item in items {
                let type = (item["type"] as? String) ?? ""
                if type == "function_call" {
                    appended = true
                    let callID = (item["call_id"] as? String) ?? (item["id"] as? String) ?? ""
                    let name = (item["name"] as? String) ?? ""
                    let arguments = (item["arguments"] as? String) ?? "{}"
                    let parsedArguments = ((try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] ?? [:])
                        .mapValues(JSONValue.from)
                    if !callID.isEmpty {
                        remembered[callID] = ResponseToolCallMemory(name: name, arguments: parsedArguments)
                    }
                    transcript.append("ASSISTANT FUNCTION_CALL: \(jsonString(["call_id": callID, "name": name, "arguments": arguments]))")
                    continue
                }
                if type == "function_call_output" {
                    appended = true
                    sawToolOutput = true
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
                if type == "compaction" {
                    appended = true
                    let content = stringValue(item["encrypted_content"])
                        ?? stringValue(item["content"])
                        ?? responseInputText(item["summary"])
                    transcript.append("COMPACTED CONVERSATION SUMMARY: \(content.isEmpty ? "[empty]" : content)")
                    continue
                }
                let role = (item["role"] as? String) ?? (type == "message" ? "assistant" : "user")
                let text = item["content"].map { contentText($0, role: role) } ?? responseInputText(item)
                if !text.isEmpty {
                    appended = true
                    transcript.append("\(role.uppercased()): \(text)")
                }
            }
            return ResponsesInputAppendResult(appended: appended, sawToolOutput: sawToolOutput)
        }
        if let items = value as? [Any] {
            var appended = false
            var sawToolOutput = false
            for item in items {
                let result = appendResponsesInput(item, to: &transcript, remembered: &remembered)
                appended = result.appended || appended
                sawToolOutput = result.sawToolOutput || sawToolOutput
            }
            return ResponsesInputAppendResult(appended: appended, sawToolOutput: sawToolOutput)
        }
        let text = responseInputText(value)
        if !text.isEmpty {
            transcript.append(text)
            return ResponsesInputAppendResult(appended: true, sawToolOutput: false)
        }
        return ResponsesInputAppendResult(appended: false, sawToolOutput: false)
    }

    private static func parseTools(_ value: Any?, disabled: Bool) -> [OpenAIToolSpec] {
        guard !disabled, let tools = value as? [[String: Any]] else { return [] }
        return tools.compactMap { tool in
            let function = tool["function"] as? [String: Any] ?? tool
            guard let name = stringValue(function["name"]) ?? stringValue(tool["name"]) else {
                return nil
            }
            let parameters = toolParameters(from: [function, tool]).map(JSONValue.from)
            return OpenAIToolSpec(
                name: name,
                description: stringValue(function["description"]) ?? stringValue(tool["description"]),
                parameters: parameters
            )
        }
    }

    private static func toolParameters(from records: [[String: Any]]) -> Any? {
        for record in records {
            for key in ["parameters", "input_schema", "inputSchema", "schema", "json_schema"] {
                if let value = record[key], !(value is NSNull) {
                    return value
                }
            }
        }
        return nil
    }

    private static func appendToolInventory(_ transcript: inout [String], tools: [OpenAIToolSpec], toolChoice: Any?) {
        guard !tools.isEmpty else { return }
        transcript.append("")
        transcript.append("LOCAL TOOL INVENTORY:")
        transcript.append("Allowed tool names: \(tools.map(\.name).joined(separator: ", "))")
        transcript.append("Use only the client's local tools for filesystem and shell work.")
        transcript.append("For local work, emit SDK built-in tool calls; the harness translates them to the matching client tool names and schemas.")
        transcript.append("When the user names a specific allowed client tool, do not substitute a different tool. OpenCode MCP/server tools exposed as provider_tool names should be requested with SDK mcp.")
        transcript.append("If you need a local tool, emit the tool call before prose. Do not write progress text such as \"creating the file\" instead of calling a tool.")
        if hasCompatibleTool("shell", in: tools) {
            transcript.append("A shell client tool is available. For general file creation or overwrite requests, prefer an SDK shell call using mkdir -p and a quoted heredoc.")
        }
        for tool in tools {
            var record: [String: Any] = ["name": tool.name]
            if let description = tool.description { record["description"] = description }
            if let parameters = tool.parameters { record["parameters"] = parameters.foundationValue }
            if let data = try? JSONSerialization.data(withJSONObject: record, options: [.withoutEscapingSlashes]),
               let json = String(data: data, encoding: .utf8) {
                transcript.append(json)
            }
        }
        if let name = toolChoiceFunctionName(toolChoice) {
            transcript.append("Use the \(name) tool if you call a tool.")
        } else if (toolChoice as? String) == "required" {
            transcript.append("You must call at least one tool.")
        }
    }

    private static func appendRequiredLocalToolHint(_ transcript: inout [String], tools: [OpenAIToolSpec], latestUserText: String) {
        transcript.append("")
        transcript.append("LOCAL TOOL REQUIRED FOR THE LATEST USER REQUEST:")
        transcript.append("The latest user request requires local filesystem or shell execution. Emit exactly one SDK tool call next and no prose.")
        if let requestedTool = explicitlyRequestedToolName(in: latestUserText, tools: tools) {
            if let mcpTarget = mcpTarget(forClientToolName: requestedTool) {
                transcript.append("Use SDK mcp now with providerIdentifier \"\(mcpTarget.provider)\", toolName \"\(mcpTarget.toolName)\", and args matching the \(requestedTool) schema. Do not use SDK shell/write as a substitute for this explicitly requested client tool. After the client returns a LOCAL TOOL RESULT, continue.")
            } else {
                transcript.append("Use the explicitly requested client tool \(requestedTool) now, with arguments matching its schema. Do not substitute a different tool. After the client returns a LOCAL TOOL RESULT, continue.")
            }
            return
        }
        if hasCompatibleTool("shell", in: tools) {
            transcript.append("Use SDK shell now. For creating or overwriting a file, run mkdir -p for the parent directory and write the file with a single quoted heredoc. After the client returns a LOCAL TOOL RESULT, continue.")
        } else {
            transcript.append("For creating or overwriting a file, use SDK write with path and fileText. After the client returns a LOCAL TOOL RESULT, continue.")
        }
    }

    private static func explicitlyRequestedToolName(in text: String, tools: [OpenAIToolSpec]) -> String? {
        let lower = text.lowercased()
        let sortedTools = tools.sorted { $0.name.count > $1.name.count }
        for tool in sortedTools {
            let name = tool.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.count > 3 else { continue }
            let loweredName = name.lowercased()
            let normalized = normalizedName(name)
            if lower.contains("\(loweredName) tool")
                || lower.contains("tool \(loweredName)")
                || lower.contains("tool named \(loweredName)")
                || lower.contains("use \(loweredName)") {
                return name
            }
            if (name.contains("_") || name.contains("-")),
               lower.contains(loweredName) || lower.contains(normalized) {
                return name
            }
        }
        return nil
    }

    private static func mcpTarget(forClientToolName name: String) -> (provider: String, toolName: String)? {
        if isKnownMappedToolName(name) {
            return nil
        }
        if name.hasPrefix("mcp__") {
            let parts = name.components(separatedBy: "__").filter { !$0.isEmpty }
            if parts.count >= 3 {
                return (provider: parts[1], toolName: parts.dropFirst(2).joined(separator: "__"))
            }
        }
        guard let separator = name.firstIndex(of: "_"),
              separator != name.startIndex,
              separator < name.index(before: name.endIndex) else {
            return nil
        }
        let provider = String(name[..<separator])
        let toolName = String(name[name.index(after: separator)...])
        guard !provider.isEmpty, !toolName.isEmpty else { return nil }
        return (provider: provider, toolName: toolName)
    }

    private static func isKnownMappedToolName(_ name: String) -> Bool {
        let knownCanonicals = ["shell", "write", "read", "delete", "grep", "glob", "ls", "readlints", "mcp", "semsearch", "todowrite"]
        let normalized = normalizedName(name)
        return knownCanonicals.contains { canonical in
            canonicalToolName(name) == canonical || toolAliases(for: canonical).map(normalizedName).contains(normalized)
        }
    }

    private static func shouldRequireLocalTool(for text: String, tools: [OpenAIToolSpec]) -> Bool {
        guard !tools.isEmpty else { return false }
        let lower = text.lowercased()
        let hasPathSignal = lower.contains("~/")
            || lower.contains("/")
            || lower.contains("desktop")
            || lower.contains("file")
            || lower.contains("folder")
            || lower.contains("directory")
            || lower.range(of: #"\b[\w.-]+\.(html|css|js|ts|tsx|jsx|json|md|txt|py|rb|go|rs|swift|toml|yaml|yml)\b"#, options: .regularExpression) != nil
        let wantsFileMutation = lower.range(of: #"\b(create|write|save|overwrite|edit|modify|update|delete|remove|make)\b"#, options: .regularExpression) != nil
        if hasPathSignal, wantsFileMutation, hasAnyCompatibleTool(["write", "shell"], in: tools) {
            return true
        }
        let wantsCommand = lower.range(of: #"\b(run|execute|start|launch)\b"#, options: .regularExpression) != nil
            && (lower.contains("command") || lower.contains("shell") || lower.contains("terminal") || lower.contains("server"))
        return wantsCommand && hasCompatibleTool("shell", in: tools)
    }

    private static func hasAnyCompatibleTool(_ canonicalNames: [String], in tools: [OpenAIToolSpec]) -> Bool {
        canonicalNames.contains { hasCompatibleTool($0, in: tools) }
    }

    private static func hasCompatibleTool(_ canonicalName: String, in tools: [OpenAIToolSpec]) -> Bool {
        let aliases = Set(toolAliases(for: canonicalName).map(normalizedName))
        return tools.contains { aliases.contains(normalizedName($0.name)) }
    }

    private static func toolChoiceFunctionName(_ toolChoice: Any?) -> String? {
        guard let choice = toolChoice as? [String: Any] else {
            return nil
        }
        if let function = choice["function"] as? [String: Any],
           let name = stringValue(function["name"]) {
            return name
        }
        if stringValue(choice["type"]) == "function",
           let name = stringValue(choice["name"]) {
            return name
        }
        return nil
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

    private static func rememberToolCalls(_ toolCalls: [[String: Any]], into remembered: inout [String: ResponseToolCallMemory]) {
        for toolCall in toolCalls {
            guard let id = toolCall["id"] as? String,
                  let function = toolCall["function"] as? [String: Any],
                  let name = function["name"] as? String else {
                continue
            }
            let argsString = function["arguments"] as? String ?? "{}"
            let argsData = Data(argsString.utf8)
            let args = ((try? JSONSerialization.jsonObject(with: argsData)) as? [String: Any] ?? [:])
                .mapValues(JSONValue.from)
            remembered[id] = ResponseToolCallMemory(name: name, arguments: args)
        }
    }

    private static func appendToolCallTranscript(_ transcript: inout [String], role: String, toolCalls: [[String: Any]]) {
        let rendered = toolCalls.compactMap { toolCall -> String? in
            guard let function = toolCall["function"] as? [String: Any] else { return nil }
            let id = (toolCall["id"] as? String) ?? "unknown"
            let name = (function["name"] as? String) ?? "unknown"
            let arguments = (function["arguments"] as? String) ?? "{}"
            return "tool_call(id: \(id), name: \(name), args: \(arguments))"
        }
        if rendered.isEmpty {
            if let data = try? JSONSerialization.data(withJSONObject: toolCalls, options: [.withoutEscapingSlashes]),
               let json = String(data: data, encoding: .utf8) {
                transcript.append("\(role.uppercased()) TOOL_CALLS: \(json)")
            }
            return
        }
        transcript.append("\(role.uppercased()) TOOL_CALLS:\n\(rendered.joined(separator: "\n"))")
    }

    private static func toolResultFeedback(
        toolCallID: String,
        toolName: String,
        text: String,
        remembered: [String: ResponseToolCallMemory]
    ) -> String {
        let rememberedCall = remembered[toolCallID]
        let record: [String: Any] = [
            "toolCallId": toolCallID,
            "toolName": toolName.isEmpty ? rememberedCall?.name ?? "" : toolName,
            "arguments": rememberedCall?.arguments.mapValues(\.foundationValue) ?? [:],
            "result": text
        ]
        let data = (try? JSONSerialization.data(withJSONObject: record, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func canMapToolCall(_ toolCall: CursorToolCall, tools: [OpenAIToolSpec]) -> Bool {
        resolveToolCall(toolCall, tools: tools) != nil
    }

    private static func toOpenAIToolCalls(_ toolCalls: [CursorToolCall], tools: [OpenAIToolSpec], responseID: String) -> [[String: Any]] {
        toolCalls.enumerated().compactMap { index, toolCall in
            guard let resolved = resolveToolCall(toolCall, tools: tools) else {
                return nil
            }
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
        toolCalls.enumerated().compactMap { index, toolCall in
            responseToolCallItem(toolCall, prepared: prepared, responseID: responseID, index: index)
        }
    }

    private static func responseToolCallItem(_ toolCall: CursorToolCall, prepared: PreparedChatRequest, responseID: String, index: Int) -> [String: Any]? {
        guard let resolved = resolveToolCall(toolCall, tools: prepared.tools) else {
            return nil
        }
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

    private static func resolveToolCall(_ toolCall: CursorToolCall, tools: [OpenAIToolSpec]) -> ResolvedToolCall? {
        guard let tool = resolveToolSpec(toolCall.name, arguments: toolCall.arguments, tools: tools) else {
            guard tools.isEmpty else { return nil }
            return ResolvedToolCall(name: toolCall.name, arguments: toolCall.arguments)
        }
        return ResolvedToolCall(
            name: tool.name,
            arguments: normalizeArguments(toolCall.arguments, sdkToolName: toolCall.name, tool: tool)
        )
    }

    private static func resolveToolSpec(_ name: String, arguments: [String: JSONValue], tools: [OpenAIToolSpec]) -> OpenAIToolSpec? {
        if let exact = tools.first(where: { $0.name == name }) { return exact }
        let normalized = normalizedName(name)
        if let caseInsensitive = tools.first(where: { normalizedName($0.name) == normalized }) {
            return caseInsensitive
        }

        let aliases = Set(toolAliases(for: name).map(normalizedName))
        if let aliased = tools.first(where: { aliases.contains(normalizedName($0.name)) }) {
            return aliased
        }

        if canonicalToolName(name) == "mcp",
           let mcpTool = resolveSpecificMCPTool(arguments: arguments, tools: tools) {
            return mcpTool
        }

        if canonicalToolName(name) == "ls",
           let glob = tools.first(where: { schemaLooksCompatible(sdkToolName: "glob", tool: $0) }) {
            return glob
        }

        if let compatible = tools
            .map({ (tool: $0, score: schemaCompatibilityScore(sdkToolName: name, tool: $0)) })
            .filter({ $0.score > 0 })
            .max(by: { $0.score < $1.score })?.tool {
            return compatible
        }

        if canEmulateWithShell(sdkToolName: name),
           let shell = tools.first(where: { schemaLooksCompatible(sdkToolName: "shell", tool: $0) }) {
            return shell
        }

        return nil
    }

    private static func resolveSpecificMCPTool(arguments: [String: JSONValue], tools: [OpenAIToolSpec]) -> OpenAIToolSpec? {
        let candidates = specificMCPToolNameCandidates(arguments: arguments)
        guard !candidates.isEmpty else { return nil }
        let normalizedCandidates = Set(candidates.map(normalizedName))
        return tools.first { tool in
            let normalizedTool = normalizedName(tool.name)
            return normalizedCandidates.contains(normalizedTool)
                || normalizedCandidates.contains(where: { normalizedTool.hasSuffix($0) })
        }
    }

    private static func specificMCPToolNameCandidates(arguments: [String: JSONValue]) -> [String] {
        let provider = firstArgument(in: arguments, keys: ["providerIdentifier", "provider_identifier", "provider", "server", "serverName", "server_name"])?.value.stringValue
        let toolName = firstArgument(in: arguments, keys: ["toolName", "tool_name", "tool", "name"])?.value.stringValue
        let values = [toolName, provider].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty }
        guard !values.isEmpty else { return [] }
        var candidates: [String] = []
        if let toolName {
            candidates.append(toolName)
        }
        if let toolName {
            for provider in mcpProviderNameVariants(provider) {
                candidates.append(contentsOf: [
                    "\(provider)__\(toolName)",
                    "\(provider)_\(toolName)",
                    "mcp__\(provider)__\(toolName)",
                    "mcp_\(provider)_\(toolName)"
                ])
            }
        }
        return candidates
    }

    private static func mcpProviderNameVariants(_ provider: String?) -> [String] {
        guard let provider = provider?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return []
        }
        var variants: [String] = []
        func append(_ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !variants.contains(trimmed) else { return }
            variants.append(trimmed)
        }
        append(provider)
        for separator in [":", "/", "\\", "."] {
            if let last = provider.split(separator: Character(separator)).last {
                append(String(last))
            }
        }
        let normalizedPrefixes = ["mcp__", "mcp_", "mcp-", "mcp:"]
        for prefix in normalizedPrefixes where provider.lowercased().hasPrefix(prefix) {
            append(String(provider.dropFirst(prefix.count)))
        }
        return variants
    }

    private static func normalizeArguments(
        _ rawArguments: [String: JSONValue],
        sdkToolName: String,
        tool: OpenAIToolSpec
    ) -> [String: JSONValue] {
        let canonical = canonicalToolName(sdkToolName)
        let arguments = canonical == "mcp" ? rawArguments : expandedToolArguments(rawArguments)
        let properties = parameterPropertyNames(tool)
        let selectedTool = normalizedName(tool.name)
        let selectedCanonical = canonicalToolName(tool.name)

        if selectedTool == "strreplaceeditor",
           ["write", "read", "edit"].contains(canonical) {
            return strReplaceEditorArguments(arguments, sdkToolName: sdkToolName, properties: properties)
        }

        guard !properties.isEmpty else { return arguments }

        if let commandStyleFile = commandStyleFileArguments(arguments, sdkToolName: sdkToolName, tool: tool, properties: properties) {
            return commandStyleFile
        }
        if let patchStyleFile = patchStyleFileArguments(arguments, sdkToolName: sdkToolName, tool: tool, properties: properties) {
            return patchStyleFile
        }

        var output: [String: JSONValue] = [:]
        var consumed = Set<String>()
        let required = requiredParameterNames(tool)
        let allowAdditionalProperties = parameterAllowsAdditionalProperties(tool)

        if canonical != "shell", selectedCanonical == "shell" {
            return shellFallbackArguments(arguments, sdkToolName: sdkToolName, tool: tool)
        }

        if canonical == "ls", selectedCanonical == "glob" {
            return listAsGlobArguments(arguments, tool: tool)
        }

        if canonical == "mcp", selectedCanonical != "mcp" {
            return specificMCPToolArguments(arguments, tool: tool)
        }

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
            if let descriptionKey = propertyName(matching: ["description"], in: properties),
               output[descriptionKey] == nil {
                let commandKey = propertyName(matching: ["command", "cmd", "script", "input"], in: properties)
                let command = commandKey.flatMap { output[$0]?.stringValue } ?? "shell command"
                output[descriptionKey] = .string(shellToolDescription(for: command))
            }
            fillRequiredShellArguments(&output, source: arguments, properties: properties, required: required)
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
            let glob = normalizedGlobArguments(arguments)
            if let patternKey = propertyName(matching: ["pattern", "globPattern", "glob_pattern", "glob"], in: properties) {
                let pattern = glob.pattern ?? .string("**/*")
                output[patternKey] = pattern
            }
            if let searchPath = glob.searchPath,
               shouldIncludeOptionalPath(searchPath),
               let pathKey = propertyName(matching: ["path", "targetDirectory", "target_directory", "directory", "cwd"], in: properties) {
                output[pathKey] = searchPath
            }
            consumed.formUnion(glob.consumed)
        case "ls":
            copy("path", as: pathPropertyAliases() + ["directory", "dir"])
            copy("ignore", as: ["ignorePatterns", "ignore_patterns", "exclude"])
            if output.isEmpty,
               let pathKey = propertyName(matching: pathPropertyAliases() + ["directory", "dir"], in: properties) {
                output[pathKey] = .string(".")
            }
        case "readlints":
            copy("paths", as: ["files", "filePaths", "file_paths"])
        case "mcp":
            copy("name", as: ["tool", "toolName", "tool_name"])
            copy("args", as: ["arguments", "input", "params", "parameters"])
            copy("providerIdentifier", as: ["provider", "server", "serverName", "server_name"])
            copy("toolName", as: ["tool", "name", "tool_name"])
        case "semsearch":
            copy("query", as: ["pattern", "search"])
            copy("targetDirectories", as: ["target_directories", "directories", "paths"])
            copy("explanation", as: ["reason", "why"])
        case "todowrite":
            copy("todos", as: ["todoList", "todo_list", "items"])
        default:
            break
        }

        for (key, value) in arguments where !consumed.contains(key) {
            if let target = propertyName(matching: [key], in: properties) {
                output[target] = value
            } else if let target = aliasPropertyName(for: key, toolName: tool.name, properties: properties),
                      output[target] == nil {
                output[target] = value
            } else if allowAdditionalProperties {
                output[key] = value
            }
        }

        if canonical == "shell",
           let commandKey = propertyName(matching: ["command", "cmd", "script", "input"], in: properties),
           let command = output[commandKey]?.stringValue,
           shouldDetachShellCommand(command) {
            output[commandKey] = .string(detachedShellCommand(command))
        }

        if canonical == "todowrite" {
            output = normalizeTodoWriteArguments(output)
        }

        return output.isEmpty ? arguments : output
    }

    private static func expandedToolArguments(_ arguments: [String: JSONValue]) -> [String: JSONValue] {
        var output: [String: JSONValue] = [:]
        for (key, value) in arguments {
            let normalized = normalizedName(key)
            if let nested = objectArgumentValue(value),
               ["arguments", "args", "input", "parameters", "params", "targeting"].contains(normalized) {
                output.merge(expandedToolArguments(nested), uniquingKeysWith: { current, _ in current })
                continue
            }
            output[key] = value
        }
        return output
    }

    private static func objectArgumentValue(_ value: JSONValue) -> [String: JSONValue]? {
        if case .object(let object) = value {
            return object
        }
        guard let string = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              string.hasPrefix("{"),
              let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object.mapValues(JSONValue.from)
    }

    private static func shellFallbackArguments(
        _ arguments: [String: JSONValue],
        sdkToolName: String,
        tool: OpenAIToolSpec
    ) -> [String: JSONValue] {
        let properties = parameterPropertyNames(tool)
        guard !properties.isEmpty,
              let commandKey = propertyName(matching: ["command", "cmd", "script", "input"], in: properties),
              let command = shellFallbackCommand(arguments, sdkToolName: sdkToolName) else {
            return arguments
        }

        var output: [String: JSONValue] = [commandKey: .string(command)]
        if let workdir = firstArgument(in: arguments, keys: ["workingDirectory", "working_directory", "workdir", "cwd", "directory"])?.value,
           let workdirKey = propertyName(matching: ["workingDirectory", "working_directory", "workdir", "cwd", "directory"], in: properties),
           shouldIncludeOptionalPath(workdir) {
            output[workdirKey] = workdir
        }
        if let timeout = firstArgument(in: arguments, keys: ["timeout", "timeoutMs", "timeout_ms", "timeoutSeconds", "timeout_seconds"])?.value,
           let timeoutKey = propertyName(matching: ["timeout", "timeoutMs", "timeout_ms", "timeoutSeconds", "timeout_seconds"], in: properties) {
            output[timeoutKey] = timeout
        }
        if let descriptionKey = propertyName(matching: ["description"], in: properties) {
            output[descriptionKey] = .string(shellToolDescription(for: command))
        }
        fillRequiredShellArguments(&output, source: arguments, properties: properties, required: requiredParameterNames(tool))
        return output
    }

    private static func specificMCPToolArguments(_ arguments: [String: JSONValue], tool: OpenAIToolSpec) -> [String: JSONValue] {
        let properties = parameterPropertyNames(tool)
        let allowAdditionalProperties = parameterAllowsAdditionalProperties(tool)
        guard !properties.isEmpty else {
            return arguments["args"]?.objectValue ?? arguments
        }
        let payload = arguments["args"].flatMap(objectArgumentValue) ?? [:]
        var output: [String: JSONValue] = [:]
        for (key, value) in expandedToolArguments(payload) {
            if let target = propertyName(matching: [key], in: properties) {
                output[target] = value
            } else if let target = aliasPropertyName(for: key, toolName: tool.name, properties: properties),
                      output[target] == nil {
                output[target] = value
            } else if allowAdditionalProperties {
                output[key] = value
            }
        }
        return output
    }

    private static func shellFallbackCommand(_ arguments: [String: JSONValue], sdkToolName: String) -> String? {
        switch canonicalToolName(sdkToolName) {
        case "write":
            guard let path = firstArgument(in: arguments, keys: pathPropertyAliases())?.value.stringValue,
                  let content = firstArgument(in: arguments, keys: ["fileText", "file_text", "content", "contents", "text", "fileContent", "file_content"])?.value.stringValue else {
                return nil
            }
            let delimiter = heredocDelimiter(for: content)
            return "mkdir -p \"$(dirname \(shellSingleQuoted(path)))\" && cat > \(shellSingleQuoted(path)) <<'\(delimiter)'\n\(content)\n\(delimiter)"
        case "read":
            guard let path = firstArgument(in: arguments, keys: pathPropertyAliases())?.value.stringValue else {
                return nil
            }
            let quotedPath = shellSingleQuoted(path)
            let offset = firstArgument(in: arguments, keys: ["offset", "start", "startLine", "start_line"])?.value.integerValue
            let limit = firstArgument(in: arguments, keys: ["limit", "maxLines", "max_lines", "lineCount", "line_count"])?.value.integerValue
            if let offset, let limit, limit > 0 {
                let start = max(1, offset)
                let end = start + limit - 1
                return "sed -n \(shellSingleQuoted("\(start),\(end)p")) \(quotedPath)"
            }
            return "cat \(quotedPath)"
        case "delete":
            guard let path = firstArgument(in: arguments, keys: pathPropertyAliases())?.value.stringValue else {
                return nil
            }
            return "rm -rf \(shellSingleQuoted(path))"
        case "grep":
            guard let pattern = firstArgument(in: arguments, keys: ["pattern", "query", "regex", "search"])?.value.stringValue else {
                return nil
            }
            let path = firstArgument(in: arguments, keys: pathPropertyAliases() + ["directory"])?.value.stringValue ?? "."
            var parts = ["rg", "--line-number", "--color", "never", "--hidden"]
            if let include = firstArgument(in: arguments, keys: ["glob", "include", "includeGlob", "include_glob"])?.value.stringValue,
               !include.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append("--glob")
                parts.append(shellSingleQuoted(include))
            }
            parts.append(shellSingleQuoted(pattern))
            parts.append(shellSingleQuoted(path))
            return parts.joined(separator: " ")
        case "glob":
            let glob = normalizedGlobArguments(arguments)
            let pattern = glob.pattern?.stringValue ?? "**/*"
            let path = glob.searchPath?.stringValue ?? "."
            return """
            python3 - <<'PY'
            from pathlib import Path
            base = Path(\(pythonStringLiteral(path)))
            pattern = \(pythonStringLiteral(pattern))
            for item in sorted(base.glob(pattern)):
                print(item)
            PY
            """
        case "ls":
            let path = firstArgument(in: arguments, keys: pathPropertyAliases() + ["directory", "dir"])?.value.stringValue ?? "."
            return "ls -la \(shellSingleQuoted(path))"
        case "semsearch":
            guard let query = firstArgument(in: arguments, keys: ["query", "pattern", "search"])?.value.stringValue else {
                return nil
            }
            let directories = firstArgument(in: arguments, keys: ["targetDirectories", "target_directories", "directories", "paths"])?.value.stringArrayValue ?? ["."]
            return (["rg", "--line-number", "--color", "never", "--hidden", shellSingleQuoted(query)] + directories.map(shellSingleQuoted)).joined(separator: " ")
        default:
            return nil
        }
    }

    private static func listAsGlobArguments(_ arguments: [String: JSONValue], tool: OpenAIToolSpec) -> [String: JSONValue] {
        let properties = parameterPropertyNames(tool)
        guard !properties.isEmpty else { return arguments }
        var output: [String: JSONValue] = [:]
        if let patternKey = propertyName(matching: ["pattern", "globPattern", "glob_pattern", "glob"], in: properties) {
            output[patternKey] = .string(arguments.isEmpty ? "**/*" : "*")
        }
        if let path = firstArgument(in: arguments, keys: pathPropertyAliases() + ["directory", "dir"])?.value,
           shouldIncludeOptionalPath(path),
           let pathKey = propertyName(matching: ["path", "targetDirectory", "target_directory", "directory", "cwd"], in: properties) {
            output[pathKey] = path
        }
        return output.isEmpty ? arguments : output
    }

    private static func fillRequiredShellArguments(
        _ output: inout [String: JSONValue],
        source: [String: JSONValue],
        properties: [String],
        required: Set<String>
    ) {
        guard !required.isEmpty else { return }
        if let workdirKey = propertyName(matching: ["workingDirectory", "working_directory", "workdir", "cwd", "directory"], in: properties),
           isRequired(workdirKey, in: required),
           output[workdirKey] == nil {
            output[workdirKey] = firstArgument(in: source, keys: ["workingDirectory", "working_directory", "workdir", "cwd", "directory"])?.value ?? .string(".")
        }
        if let timeoutKey = propertyName(matching: ["timeout", "timeoutMs", "timeout_ms", "timeoutSeconds", "timeout_seconds"], in: properties),
           isRequired(timeoutKey, in: required),
           output[timeoutKey] == nil {
            output[timeoutKey] = firstArgument(in: source, keys: ["timeout", "timeoutMs", "timeout_ms", "timeoutSeconds", "timeout_seconds"])?.value ?? .number(120_000)
        }
        if let descriptionKey = propertyName(matching: ["description"], in: properties),
           isRequired(descriptionKey, in: required),
           output[descriptionKey] == nil {
            let commandKey = propertyName(matching: ["command", "cmd", "script", "input"], in: properties)
            let command = commandKey.flatMap { output[$0]?.stringValue } ?? "shell command"
            output[descriptionKey] = .string(shellToolDescription(for: command))
        }
    }

    private struct NamedArgument {
        var key: String
        var value: JSONValue
    }

    private struct GlobArguments {
        var pattern: JSONValue?
        var searchPath: JSONValue?
        var consumed: Set<String>
    }

    private static func normalizedGlobArguments(_ arguments: [String: JSONValue]) -> GlobArguments {
        let patternKeys = ["globPattern", "glob_pattern", "pattern", "glob"]
        let pathKeys = ["targetDirectory", "target_directory", "directory", "cwd", "path"]
        var pattern = firstArgument(in: arguments, keys: patternKeys)
        var searchPath = firstArgument(in: arguments, keys: pathKeys)
        var consumed = Set<String>()

        if let key = pattern?.key { consumed.insert(key) }
        if let key = searchPath?.key { consumed.insert(key) }

        let patternLooksGlob = pattern?.value.stringValue.map(looksLikeGlobPattern) ?? false
        let pathLooksGlob = searchPath?.value.stringValue.map(looksLikeGlobPattern) ?? false

        if pathLooksGlob && !patternLooksGlob {
            swap(&pattern, &searchPath)
        } else if pattern == nil, pathLooksGlob {
            pattern = searchPath
            searchPath = nil
        }

        if let key = pattern?.key { consumed.insert(key) }
        if let key = searchPath?.key { consumed.insert(key) }

        return GlobArguments(pattern: pattern?.value, searchPath: searchPath?.value, consumed: consumed)
    }

    private static func firstArgument(in arguments: [String: JSONValue], keys: [String]) -> NamedArgument? {
        for key in keys {
            if let value = arguments[key] {
                return NamedArgument(key: key, value: value)
            }
        }
        let normalizedKeys = Set(keys.map(normalizedName))
        for (key, value) in arguments where normalizedKeys.contains(normalizedName(key)) {
            return NamedArgument(key: key, value: value)
        }
        return nil
    }

    private static func looksLikeGlobPattern(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.contains("*")
            || trimmed.contains("?")
            || trimmed.contains("[")
            || trimmed.contains("]")
            || trimmed.contains("{")
            || trimmed.contains("}")
    }

    private static func shouldIncludeOptionalPath(_ value: JSONValue) -> Bool {
        guard let string = value.stringValue else { return true }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lower = trimmed.lowercased()
        return lower != "undefined" && lower != "null"
    }

    private static func normalizeTodoWriteArguments(_ arguments: [String: JSONValue]) -> [String: JSONValue] {
        guard case .array(let todos)? = arguments["todos"] else {
            return arguments
        }
        var output = arguments
        output["todos"] = .array(todos.map { item in
            guard case .object(var todo) = item else {
                return item
            }
            if let status = todo["status"]?.stringValue {
                todo["status"] = .string(normalizedTodoStatus(status))
            }
            if shouldDefaultTodoPriority(todo["priority"]) {
                todo["priority"] = .string("medium")
            }
            return .object(todo)
        })
        return output
    }

    private static func shouldDefaultTodoPriority(_ value: JSONValue?) -> Bool {
        guard let value else { return true }
        if case .null = value { return true }
        if let string = value.stringValue {
            return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return false
    }

    private static func normalizedTodoStatus(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "[\\s-]+", with: "_", options: .regularExpression) {
        case "todo_status_pending", "todo", "pending":
            return "pending"
        case "todo_status_inprogress", "todo_status_in_progress", "inprogress", "in_progress":
            return "in_progress"
        case "todo_status_done", "todo_status_complete", "todo_status_completed", "done", "complete", "completed":
            return "completed"
        default:
            return value
        }
    }

    private static func shouldDetachShellCommand(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let lower = trimmed.lowercased()
        if trimmed.hasSuffix("&")
            || lower.contains(" nohup ")
            || lower.hasPrefix("nohup ")
            || lower.contains(" disown")
            || lower.hasPrefix("tmux ")
            || lower.contains(" tmux ")
            || lower.hasPrefix("screen ")
            || lower.contains(" screen ")
            || lower.contains(" --detach")
            || lower.contains(" -d ") {
            return false
        }

        let patterns = [
            #"(?i)(^|[;&|]\s*)(python3?|uv)\s+-m\s+http\.server\b"#,
            #"(?i)(^|[;&|]\s*)python3?\s+-m\s+simplehttpserver\b"#,
            #"(?i)(^|[;&|]\s*)(npm|pnpm|yarn|bun)\s+(run\s+)?(dev|start|serve|preview)\b"#,
            #"(?i)(^|[;&|]\s*)(vite|next|nuxt|astro|webpack-dev-server)\b"#,
            #"(?i)(^|[;&|]\s*)webpack\s+serve\b"#,
            #"(?i)(^|[;&|]\s*)python3?\s+manage\.py\s+runserver\b"#,
            #"(?i)(^|[;&|]\s*)(flask\s+run|fastapi\s+dev|uvicorn|gunicorn)\b"#,
            #"(?i)(^|[;&|]\s*)(rails\s+server|bin/rails\s+server|bundle\s+exec\s+rails\s+server)\b"#,
            #"(?i)(^|[;&|]\s*)tail\s+-f\b"#,
            #"(?i)(^|[;&|]\s*)(watchexec|nodemon|ts-node-dev)\b"#
        ]
        return patterns.contains { pattern in
            trimmed.range(of: pattern, options: .regularExpression) != nil
        }
    }

    private static func shellToolDescription(for command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.contains("cat >") || lower.contains("tee ") || lower.contains("mkdir -p") {
            return "Create requested file"
        }
        if trimmed.contains("\n") || trimmed.count > 80 {
            return "Run local shell command"
        }
        return "Run \(trimmed.isEmpty ? "shell command" : trimmed)"
    }

    private static func detachedShellCommand(_ command: String) -> String {
        let logPath = "/tmp/api-for-cursor/dev-server-\(Int(Date().timeIntervalSince1970)).log"
        return "mkdir -p /tmp/api-for-cursor && nohup sh -lc \(shellSingleQuoted(command)) > \(shellSingleQuoted(logPath)) 2>&1 < /dev/null & echo \"Started background process $! (log: \(logPath))\""
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func heredocDelimiter(for content: String) -> String {
        for index in 0...100 {
            let suffix = index == 0 ? "" : "_\(index)"
            let delimiter = "API_FOR_CURSOR_EOF\(suffix)"
            if !content.contains(delimiter) {
                return delimiter
            }
        }
        return "API_FOR_CURSOR_EOF_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
    }

    private static func pythonStringLiteral(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data(#""""#.utf8)
        return String(data: data, encoding: .utf8) ?? #""""#
    }

    private static func strReplaceEditorArguments(_ arguments: [String: JSONValue], sdkToolName: String, properties: [String]) -> [String: JSONValue] {
        let fallbackProperties = properties.isEmpty ? ["command", "path", "file_text", "old_str", "new_str", "view_range"] : properties
        var output: [String: JSONValue] = [:]
        if let path = firstArgument(in: arguments, keys: pathPropertyAliases() + ["target_file", "targetFile"])?.value,
           let pathKey = propertyName(matching: pathPropertyAliases(), in: fallbackProperties) {
            output[pathKey] = path
        }

        let commandKey = propertyName(matching: ["command"], in: fallbackProperties)
        switch canonicalToolName(sdkToolName) {
        case "read":
            if let commandKey {
                output[commandKey] = .string("view")
            }
            if let viewRange = viewRange(from: arguments),
               let viewRangeKey = propertyName(matching: ["view_range", "viewRange", "range"], in: fallbackProperties) {
                output[viewRangeKey] = viewRange
            }
        case "edit":
            if let oldText = firstArgument(in: arguments, keys: ["oldString", "old_string", "old_str", "oldText", "old_text", "search", "searchString", "search_string"])?.value,
               let newText = firstArgument(in: arguments, keys: ["newString", "new_string", "new_str", "newText", "new_text", "replacement", "replace"])?.value {
                if let commandKey {
                    output[commandKey] = .string("str_replace")
                }
                if let oldKey = propertyName(matching: ["old_str", "oldString", "old_string", "old"], in: fallbackProperties) {
                    output[oldKey] = oldText
                }
                if let newKey = propertyName(matching: ["new_str", "newString", "new_string", "replacement"], in: fallbackProperties) {
                    output[newKey] = newText
                }
                return output.isEmpty ? arguments : output
            }
            fallthrough
        default:
            if let commandKey {
                output[commandKey] = .string("create")
            }
            if let fileText = firstArgument(in: arguments, keys: ["fileText", "file_text", "content", "contents", "text", "fileContent", "file_content", "streamContent"])?.value,
               let contentKey = propertyName(matching: ["file_text", "fileText", "content", "contents", "text"], in: fallbackProperties) {
                output[contentKey] = fileText
            }
        }
        return output.isEmpty ? arguments : output
    }

    private static func viewRange(from arguments: [String: JSONValue]) -> JSONValue? {
        let offset = firstArgument(in: arguments, keys: ["offset", "start", "startLine", "start_line"])?.value.integerValue
        let limit = firstArgument(in: arguments, keys: ["limit", "maxLines", "max_lines", "lineCount", "line_count"])?.value.integerValue
        guard offset != nil || limit != nil else { return nil }
        let start = max(1, offset ?? 1)
        guard let limit, limit > 0 else {
            return .array([.number(Double(start)), .number(-1)])
        }
        return .array([.number(Double(start)), .number(Double(start + limit - 1))])
    }

    private static func commandStyleFileArguments(
        _ arguments: [String: JSONValue],
        sdkToolName: String,
        tool: OpenAIToolSpec,
        properties: [String]
    ) -> [String: JSONValue]? {
        let canonical = canonicalToolName(sdkToolName)
        guard ["write", "read", "edit", "delete"].contains(canonical),
              let operationKey = propertyName(matching: operationPropertyAliases(), in: properties),
              let pathKey = propertyName(matching: pathPropertyAliases(), in: properties),
              let path = firstArgument(in: arguments, keys: pathPropertyAliases() + ["target_file", "targetFile"])?.value,
              shouldIncludeOptionalPath(path) else {
            return nil
        }

        var output: [String: JSONValue] = [
            operationKey: .string(operationValue(for: canonical, property: operationKey, tool: tool)),
            pathKey: path
        ]

        switch canonical {
        case "write":
            guard let content = firstArgument(in: arguments, keys: ["fileText", "file_text", "content", "contents", "text", "fileContent", "file_content", "streamContent"])?.value,
                  let contentKey = propertyName(matching: ["content", "contents", "fileText", "file_text", "fileContent", "file_content", "text"], in: properties) else {
                return nil
            }
            output[contentKey] = content
        case "edit":
            guard let oldText = firstArgument(in: arguments, keys: ["oldString", "old_string", "old_str", "oldText", "old_text", "search", "searchString", "search_string"])?.value,
                  let newText = firstArgument(in: arguments, keys: ["newString", "new_string", "new_str", "newText", "new_text", "replacement", "replace", "content"])?.value,
                  let oldKey = propertyName(matching: ["oldString", "old_string", "old_str", "old", "search", "searchString", "search_string"], in: properties),
                  let newKey = propertyName(matching: ["newString", "new_string", "new_str", "replacement", "replace", "content"], in: properties) else {
                return nil
            }
            output[oldKey] = oldText
            output[newKey] = newText
        case "read":
            copyOptionalArgument(&output, from: arguments, properties: properties, candidates: ["offset", "start", "startLine", "start_line"])
            copyOptionalArgument(&output, from: arguments, properties: properties, candidates: ["limit", "maxLines", "max_lines", "lineCount", "line_count"])
        default:
            break
        }
        return output
    }

    private static func copyOptionalArgument(
        _ output: inout [String: JSONValue],
        from arguments: [String: JSONValue],
        properties: [String],
        candidates: [String]
    ) {
        guard let value = firstArgument(in: arguments, keys: candidates)?.value,
              let key = propertyName(matching: candidates, in: properties) else {
            return
        }
        output[key] = value
    }

    private static func commandStyleFileToolSupports(_ canonical: String, tool: OpenAIToolSpec, properties: [String]) -> Bool {
        guard ["write", "read", "edit", "delete"].contains(canonical),
              propertyName(matching: operationPropertyAliases(), in: properties) != nil,
              propertyName(matching: pathPropertyAliases(), in: properties) != nil else {
            return false
        }
        switch canonical {
        case "write":
            return propertyName(matching: ["content", "contents", "fileText", "file_text", "fileContent", "file_content", "text"], in: properties) != nil
        case "edit":
            return propertyName(matching: ["oldString", "old_string", "old_str", "old", "search", "searchString", "search_string"], in: properties) != nil
                && propertyName(matching: ["newString", "new_string", "new_str", "replacement", "replace", "content"], in: properties) != nil
        default:
            return true
        }
    }

    private static func operationPropertyAliases() -> [String] {
        ["command", "action", "operation", "op", "mode"]
    }

    private static func operationValue(for canonical: String, property: String, tool: OpenAIToolSpec) -> String {
        let candidates: [String]
        switch canonical {
        case "write":
            candidates = ["write", "create", "overwrite", "replace"]
        case "read":
            candidates = ["read", "view", "open"]
        case "edit":
            candidates = ["replace", "str_replace", "edit", "update"]
        case "delete":
            candidates = ["delete", "remove"]
        default:
            candidates = [canonical]
        }

        let allowed = stringEnumValues(for: property, tool: tool)
        for candidate in candidates {
            if let match = allowed.first(where: { normalizedName($0) == normalizedName(candidate) }) {
                return match
            }
        }
        return candidates.first ?? canonical
    }

    private static func stringEnumValues(for property: String, tool: OpenAIToolSpec) -> [String] {
        guard let propertySchema = parameterPropertySchema(property, tool: tool),
              case .object(let schema) = propertySchema,
              case .array(let values)? = schema["enum"] else {
            return []
        }
        return values.compactMap(\.stringValue)
    }

    private static func parameterPropertySchema(_ property: String, tool: OpenAIToolSpec) -> JSONValue? {
        guard case .object(let root)? = tool.parameters,
              case .object(let properties)? = root["properties"] else {
            return nil
        }
        return properties[property]
    }

    private static func patchStyleFileArguments(
        _ arguments: [String: JSONValue],
        sdkToolName: String,
        tool: OpenAIToolSpec,
        properties: [String]
    ) -> [String: JSONValue]? {
        let canonical = canonicalToolName(sdkToolName)
        guard ["write", "edit", "delete"].contains(canonical),
              let patchKey = patchPropertyKey(tool: tool, properties: properties),
              let path = firstArgument(in: arguments, keys: pathPropertyAliases() + ["target_file", "targetFile"])?.value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return nil
        }

        let patch: String
        switch canonical {
        case "write":
            guard let content = firstArgument(in: arguments, keys: ["fileText", "file_text", "content", "contents", "text", "fileContent", "file_content", "streamContent"])?.value.stringValue else {
                return nil
            }
            patch = addFilePatch(path: path, content: content)
        case "edit":
            guard let oldText = firstArgument(in: arguments, keys: ["oldString", "old_string", "old_str", "oldText", "old_text", "search", "searchString", "search_string"])?.value.stringValue,
                  let newText = firstArgument(in: arguments, keys: ["newString", "new_string", "new_str", "newText", "new_text", "replacement", "replace", "content"])?.value.stringValue else {
                return nil
            }
            patch = updateFilePatch(path: path, oldText: oldText, newText: newText)
        default:
            patch = deleteFilePatch(path: path)
        }

        var output: [String: JSONValue] = [patchKey: .string(patch)]
        if let pathKey = propertyName(matching: pathPropertyAliases(), in: properties) {
            output[pathKey] = .string(path)
        }
        return output
    }

    private static func patchStyleFileToolSupports(_ canonical: String, tool: OpenAIToolSpec, properties: [String]) -> Bool {
        guard ["write", "edit", "delete"].contains(canonical) else {
            return false
        }
        return patchPropertyKey(tool: tool, properties: properties) != nil
    }

    private static func patchPropertyKey(tool: OpenAIToolSpec, properties: [String]) -> String? {
        if let direct = propertyName(matching: ["patch", "diff", "unifiedDiff", "unified_diff"], in: properties) {
            return direct
        }
        guard normalizedName(tool.name).contains("patch") else {
            return nil
        }
        return propertyName(matching: ["input", "content", "text"], in: properties)
    }

    private static func addFilePatch(path: String, content: String) -> String {
        (["*** Begin Patch", "*** Add File: \(path)"] + patchLines(content, prefix: "+") + ["*** End Patch"]).joined(separator: "\n")
    }

    private static func updateFilePatch(path: String, oldText: String, newText: String) -> String {
        (["*** Begin Patch", "*** Update File: \(path)", "@@"] + patchLines(oldText, prefix: "-") + patchLines(newText, prefix: "+") + ["*** End Patch"]).joined(separator: "\n")
    }

    private static func deleteFilePatch(path: String) -> String {
        ["*** Begin Patch", "*** Delete File: \(path)", "*** End Patch"].joined(separator: "\n")
    }

    private static func patchLines(_ text: String, prefix: String) -> [String] {
        var lines = text.components(separatedBy: .newlines)
        if lines.last == "" {
            lines.removeLast()
        }
        if lines.isEmpty {
            lines = [""]
        }
        return lines.map { "\(prefix)\($0)" }
    }

    private static func schemaLooksCompatible(sdkToolName: String, tool: OpenAIToolSpec) -> Bool {
        let properties = parameterPropertyNames(tool)
        guard !properties.isEmpty else { return false }
        func has(_ candidates: [String]) -> Bool {
            propertyName(matching: candidates, in: properties) != nil
        }
        let canonical = canonicalToolName(sdkToolName)
        if normalizedName(tool.name) == "strreplaceeditor",
           !["write", "read", "edit"].contains(canonical) {
            return false
        }
        if commandStyleFileToolSupports(canonical, tool: tool, properties: properties) {
            return true
        }
        if patchStyleFileToolSupports(canonical, tool: tool, properties: properties) {
            return true
        }
        switch canonical {
        case "shell":
            return has(["command", "cmd", "script"])
        case "write":
            return has(pathPropertyAliases()) && has(["fileText", "file_text", "content", "contents", "text"])
        case "read", "delete":
            return has(pathPropertyAliases())
        case "edit":
            return has(pathPropertyAliases()) && has(["oldString", "old_string", "old_str", "old", "search", "newString", "new_string", "new_str", "replacement"])
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
        case "todowrite":
            return has(["todos", "todoList", "todo_list", "items"])
        default:
            return false
        }
    }

    private static func schemaCompatibilityScore(sdkToolName: String, tool: OpenAIToolSpec) -> Int {
        guard schemaLooksCompatible(sdkToolName: sdkToolName, tool: tool) else { return 0 }
        let sdkCanonical = canonicalToolName(sdkToolName)
        let toolCanonical = canonicalToolName(tool.name)
        if toolCanonical == sdkCanonical { return 100 }
        if toolAliases(for: sdkToolName).map(normalizedName).contains(normalizedName(tool.name)) { return 95 }
        if sdkCanonical == "write", normalizedName(tool.name).contains("edit") { return 80 }
        if sdkCanonical == "ls", toolCanonical == "read" { return 20 }
        return 50
    }

    private static func canEmulateWithShell(sdkToolName: String) -> Bool {
        switch canonicalToolName(sdkToolName) {
        case "write", "read", "delete", "grep", "glob", "ls", "semsearch":
            return true
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

    private static func requiredParameterNames(_ tool: OpenAIToolSpec) -> Set<String> {
        guard case .object(let root)? = tool.parameters,
              case .array(let required)? = root["required"] else {
            return []
        }
        return Set(required.compactMap(\.stringValue).map(normalizedName))
    }

    private static func isRequired(_ property: String, in required: Set<String>) -> Bool {
        required.contains(normalizedName(property))
    }

    private static func parameterAllowsAdditionalProperties(_ tool: OpenAIToolSpec) -> Bool {
        guard case .object(let root)? = tool.parameters,
              let additional = root["additionalProperties"] else {
            return false
        }
        if case .bool(true) = additional {
            return true
        }
        if case .object = additional {
            return true
        }
        return false
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

    private static func aliasPropertyName(for sourceKey: String, toolName: String, properties: [String]) -> String? {
        let normalizedKey = normalizedName(sourceKey)
        let candidates = toolSpecificArgumentAliases(toolName: normalizedName(toolName), normalizedKey: normalizedKey)
            + commonArgumentAliases(normalizedKey)
        return propertyName(matching: candidates, in: properties)
    }

    private static func commonArgumentAliases(_ normalizedKey: String) -> [String] {
        switch normalizedKey {
        case "absolutepath", "filepath", "filename", "targetfile", "file":
            return pathPropertyAliases()
        case "commandline", "cmd", "command", "script":
            return ["command", "cmd", "script", "input"]
        case "contents", "content", "filetext", "newcontents", "newtext":
            return ["content", "contents", "text", "fileText", "file_text", "newString", "replacement"]
        case "newstring", "replacement", "replace":
            return ["newString", "replacement", "content", "text"]
        case "oldcontents", "oldstring", "oldtext", "searchstring":
            return ["oldString", "old", "search", "text"]
        case "glob", "globpattern", "include":
            return ["include", "pattern", "glob"]
        case "pattern", "query", "regex", "search":
            return ["pattern", "query", "regex", "search", "prompt"]
        case "targetdirectory", "targeting", "directory", "cwd", "workingdirectory", "workdir":
            return ["path", "directory", "cwd", "workdir", "filePath", "pattern"]
        case "prompt", "instructions":
            return ["prompt", "description", "instructions", "query"]
        case "tasks", "todo", "items":
            return ["todos", "items", "tasks"]
        case "url", "uri", "href":
            return ["url", "uri", "href"]
        default:
            return []
        }
    }

    private static func toolSpecificArgumentAliases(toolName: String, normalizedKey: String) -> [String] {
        switch canonicalToolName(toolName) {
        case "glob":
            if ["globpattern", "glob", "include", "pattern"].contains(normalizedKey) {
                return ["pattern", "glob", "include"]
            }
            if ["targeting", "targetdirectory", "cwd", "directory", "path"].contains(normalizedKey) {
                return ["path", "directory", "cwd"]
            }
        case "grep":
            if ["query", "search", "searchstring", "regex", "pattern"].contains(normalizedKey) {
                return ["pattern", "query", "regex", "search"]
            }
            if ["globpattern", "glob", "include"].contains(normalizedKey) {
                return ["include", "glob", "files"]
            }
        case "read", "delete":
            if ["targeting", "targetfile", "filepath", "absolutepath", "path", "file"].contains(normalizedKey) {
                return pathPropertyAliases()
            }
        case "write":
            if ["targeting", "targetfile", "filepath", "absolutepath", "path", "file"].contains(normalizedKey) {
                return pathPropertyAliases()
            }
            if ["newcontents", "contents", "content", "text", "filetext"].contains(normalizedKey) {
                return ["content", "text", "newString", "fileText", "file_text"]
            }
        case "shell":
            if ["cmd", "commandline", "command", "script"].contains(normalizedKey) {
                return ["command", "cmd", "script", "input"]
            }
            if ["workingdirectory", "cwd", "directory", "path", "workdir"].contains(normalizedKey) {
                return ["workdir", "cwd", "directory", "path"]
            }
        case "todowrite":
            if ["todos", "tasks", "items"].contains(normalizedKey) {
                return ["todos", "tasks", "items"]
            }
        default:
            break
        }
        return []
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
        case "updatetodos", "updatetodostoolcall", "writetodos", "todowrite", "todowritetoolcall":
            return "todowrite"
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
        case "todowrite":
            return ["todowrite", "todo_write", "update_todos", "updateTodos", "write_todos"]
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
        let promptTokens = inputTokenEstimate(characters: promptCharacters)
        let completionTokens = max(0, Int(ceil(Double(completionCharacters) / 4.0)))
        return [
            "prompt_tokens": promptTokens,
            "completion_tokens": completionTokens,
            "total_tokens": promptTokens + completionTokens
        ]
    }

    private static func responsesUsage(promptCharacters: Int, outputCharacters: Int) -> [String: Any] {
        let inputTokens = inputTokenEstimate(characters: promptCharacters)
        let outputTokens = max(0, Int(ceil(Double(outputCharacters) / 4.0)))
        return [
            "input_tokens": inputTokens,
            "input_tokens_details": ["cached_tokens": 0],
            "output_tokens": outputTokens,
            "output_tokens_details": ["reasoning_tokens": 0],
            "total_tokens": inputTokens + outputTokens,
            "prompt_tokens": inputTokens,
            "completion_tokens": outputTokens
        ]
    }

    private static func inputTokenEstimate(characters: Int) -> Int {
        max(1, Int(ceil(Double(characters) / 4.0)))
    }

    private static func serializedLength(_ value: Any) -> Int {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else {
            return 0
        }
        return data.count
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

private extension JSONValue {
    var integerValue: Int? {
        switch self {
        case .number(let value):
            return Int(value)
        case .string(let value):
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    var stringArrayValue: [String]? {
        switch self {
        case .array(let values):
            let strings = values.compactMap(\.stringValue)
            return strings.isEmpty ? nil : strings
        case .string(let value):
            return [value]
        default:
            return nil
        }
    }
}

private func + (lhs: [String: Any], rhs: [String: Any]) -> [String: Any] {
    var copy = lhs
    for (key, value) in rhs {
        copy[key] = value
    }
    return copy
}
