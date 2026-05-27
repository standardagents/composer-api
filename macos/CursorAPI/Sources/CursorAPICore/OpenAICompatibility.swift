import Foundation

public struct OpenAIToolSpec: Codable, Equatable, Sendable {
    public var name: String
    public var description: String?
    public var parameters: JSONValue?
}

public struct ResponseToolCallMemory: Equatable, Sendable {
    public var name: String
    public var arguments: [String: JSONValue]
    public var sdkName: String?
    public var sdkArguments: [String: JSONValue]?

    public init(name: String, arguments: [String: JSONValue], sdkName: String? = nil, sdkArguments: [String: JSONValue]? = nil) {
        self.name = name
        self.arguments = arguments
        self.sdkName = sdkName
        self.sdkArguments = sdkArguments
    }
}

private struct SDKToolCallMemory: Sendable {
    var name: String
    var arguments: [String: JSONValue]
}

private final class SDKToolCallMemoryStore: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: SDKToolCallMemory] = [:]
    private var order: [String] = []
    private let limit = 2_048

    func remember(id: String, name: String, arguments: [String: JSONValue]) {
        lock.lock()
        defer { lock.unlock() }
        if values[id] == nil {
            order.append(id)
        }
        values[id] = SDKToolCallMemory(name: name, arguments: arguments)
        pruneLocked()
    }

    func memory(id: String) -> SDKToolCallMemory? {
        lock.lock()
        defer { lock.unlock() }
        return values[id]
    }

    private func pruneLocked() {
        guard order.count > limit else { return }
        for key in order.prefix(order.count - limit) {
            values.removeValue(forKey: key)
        }
        order.removeFirst(order.count - limit)
    }
}

public struct ToolCallContext: Equatable, Sendable {
    public var workingDirectory: String?
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
    public var toolContext: ToolCallContext?
}

public enum OpenAICompatibility {
    private static let toolResultContinuation = "The above tool calls have been executed. Continue your response based on these results."
    private static let sdkToolCallMemory = SDKToolCallMemoryStore()

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
        let toolContext = toolCallContext(fromMessages: messages)
        let model = try ComposerModels.resolvedModelID(for: raw["model"] as? String)
        var transcript = [
            "You are running through a local Cursor SDK-compatible harness.",
            "The client owns local tool execution. When local inspection, shell commands, or file changes are needed, request a tool call and wait for the tool result.",
            "When the conversation includes LOCAL TOOL RESULT records, treat them as completed SDK tool_call results for your previous tool requests and continue from those results.",
            "If the user explicitly names an allowed client tool, use that tool. Non-builtin client tools and OpenCode MCP/server tools are called through SDK mcp with providerIdentifier, toolName, and args.",
            "For general file creation when no specific client tool is requested, prefer SDK shell when a shell client tool is available; otherwise request write calls with both path and fileText.",
            "Do not claim that you created, edited, inspected, or ran anything locally unless you emitted a tool call and received a LOCAL TOOL RESULT confirming it.",
            "When starting a dev server or other long-running watcher, start it in the background with output redirected and return immediately.",
            "Do not say that agent mode or tools are unavailable."
        ]
        appendToolInventory(&transcript, tools: tools, toolChoice: raw["tool_choice"], context: toolContext)
        transcript.append("")
        transcript.append("Conversation:")
        var rememberedToolCalls: [String: ResponseToolCallMemory] = [:]
        var sawToolResult = false
        var latestUserText = ""
        var mutationToolCallAfterLatestUser = false

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
                transcript.append("LOCAL TOOL RESULT: \(toolResultFeedback(toolCallID: toolCallID, toolName: toolName, text: text, remembered: rememberedToolCalls, tools: tools))")
            } else {
                transcript.append("\(role.uppercased()): \(text.isEmpty ? "[empty]" : text)")
                if role == "user", !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    latestUserText = text
                    mutationToolCallAfterLatestUser = false
                }
            }

            if let toolCalls = item["tool_calls"] as? [[String: Any]] {
                appendToolCallTranscript(&transcript, role: role, toolCalls: toolCalls)
                rememberToolCalls(toolCalls, into: &rememberedToolCalls)
                let requestedTool = explicitlyRequestedToolName(in: latestUserText, tools: tools)
                if !latestUserText.isEmpty,
                   toolCalls.contains(where: { toolCall in
                       isWorkspaceMutationToolCall(toolCall, tools: tools)
                           || (requestedTool.map { requested in
                               isSpecificToolCall(toolCall, requestedTool: requested, tools: tools)
                           } ?? false)
                   }) {
                    mutationToolCallAfterLatestUser = true
                }
            }
        }
        if sawToolResult {
            transcript.append("")
            transcript.append(toolResultContinuation)
        }
        let localToolRequired = shouldRequireLocalTool(for: latestUserText, tools: tools)
        if localToolRequired, !mutationToolCallAfterLatestUser {
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
            responseInputItems: [],
            toolContext: toolContext
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
            responseInputItems: [],
            toolContext: nil
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
            responseInputItems: normalizedResponseInputItems(raw["input"]),
            toolContext: nil
        )
    }

    static func prepareResponsesRequest(_ body: Data, rememberedToolCalls: [String: ResponseToolCallMemory]) throws -> PreparedChatRequest {
        let raw = try jsonObject(body)
        let model = try ComposerModels.resolvedModelID(for: raw["model"] as? String)
        let instructions = (raw["instructions"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let tools = parseTools(raw["tools"], disabled: (raw["tool_choice"] as? String) == "none")
        let toolContext = toolCallContext(fromResponseInput: raw["input"], instructions: instructions)
        let previousResponseID = (raw["previous_response_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        var transcript = [
            "You are running through a local Cursor SDK-compatible harness.",
            "The client owns local tool execution. When local inspection, shell commands, or file changes are needed, request a function_call and wait for the function_call_output.",
            "When the input includes function_call_output records, treat them as completed local tool results for your previous function_call requests and continue from those results.",
            "If the user explicitly names an allowed client tool, use that tool. Non-builtin client tools and OpenCode MCP/server tools are called through SDK mcp with providerIdentifier, toolName, and args.",
            "For general file creation when no specific client tool is requested, prefer SDK shell when a shell client tool is available; otherwise request write calls with both path and fileText.",
            "Do not claim that you created, edited, inspected, or ran anything locally unless you emitted a function_call and received a function_call_output confirming it.",
            "When starting a dev server or other long-running watcher, start it in the background with output redirected and return immediately.",
            "Do not say that agent mode or tools are unavailable."
        ]
        appendToolInventory(&transcript, tools: tools, toolChoice: raw["tool_choice"], context: toolContext)
        if let instructions, !instructions.isEmpty {
            transcript.append("")
            transcript.append("INSTRUCTIONS:")
            transcript.append(instructions)
        }
        transcript.append("")
        transcript.append("INPUT:")
        var rememberedToolCalls = rememberedToolCalls
        let input = raw["input"]
        let latestUserText = latestUserText(from: input)
        let appendedInput = appendResponsesInput(input, to: &transcript, remembered: &rememberedToolCalls, tools: tools)
        if !appendedInput.appended {
            transcript.append("[empty]")
        }
        if appendedInput.sawToolOutput {
            transcript.append("")
            transcript.append(toolResultContinuation)
        }
        let localToolRequired = shouldRequireLocalTool(for: latestUserText, tools: tools)
        let localToolDone = hasResponseWorkspaceMutationToolCallAfterLatestUser(input, tools: tools)
        if localToolRequired, !localToolDone {
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
            requestedSessionKey: responseSessionHint(raw),
            previousResponseID: previousResponseID,
            storeResponse: raw["store"] as? Bool ?? true,
            responseInputItems: normalizedResponseInputItems(input),
            toolContext: toolContext
        )
    }

    public static func responseToolCallMemory(
        id: String,
        prepared: PreparedChatRequest,
        output: CursorSDKOutput
    ) -> [String: ResponseToolCallMemory] {
        let suffix = id.replacingOccurrences(of: "[^A-Za-z0-9]", with: "", options: .regularExpression).suffix(18)
        return Dictionary(uniqueKeysWithValues: output.toolCalls.enumerated().compactMap { index, toolCall in
            guard let resolved = resolveToolCall(toolCall, tools: prepared.tools, context: prepared.toolContext) else {
                return nil
            }
            let normalizedToolCall = normalizeSDKToolCall(toolCall)
            let sdkCanonical = canonicalToolName(normalizedToolCall.name)
            let callID = "call_\(suffix)_\(sdkCanonical)_\(index)"
            sdkToolCallMemory.remember(id: callID, name: sdkCanonical, arguments: normalizedToolCall.arguments)
            return (
                callID,
                ResponseToolCallMemory(
                    name: resolved.name,
                    arguments: resolved.arguments,
                    sdkName: sdkCanonical,
                    sdkArguments: normalizedToolCall.arguments
                )
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
        let toolCalls = toOpenAIToolCalls(output.toolCalls, tools: prepared.tools, responseID: id, context: prepared.toolContext)
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
        guard let converted = toOpenAIToolCalls([toolCall], tools: prepared.tools, responseID: "\(id)_\(index)", context: prepared.toolContext).first else {
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
        let toolCalls = toOpenAIToolCalls(output.toolCalls, tools: prepared.tools, responseID: id, context: prepared.toolContext)
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

    private static func toolCallContext(fromMessages messages: [[String: Any]]) -> ToolCallContext? {
        let workingDirectory = messages
            .map { contentText($0["content"], role: ($0["role"] as? String) ?? "user") }
            .compactMap(workingDirectory(from:))
            .first
        return workingDirectory.map { ToolCallContext(workingDirectory: $0) }
    }

    private static func toolCallContext(fromResponseInput input: Any?, instructions: String?) -> ToolCallContext? {
        var texts: [String] = []
        if let instructions, !instructions.isEmpty {
            texts.append(instructions)
        }
        texts.append(responseInputText(input))
        let workingDirectory = texts.compactMap(workingDirectory(from:)).first
        return workingDirectory.map { ToolCallContext(workingDirectory: $0) }
    }

    private static func workingDirectory(from text: String) -> String? {
        for pattern in [
            #"(?im)^\s*Working directory:\s*(.+)$"#,
            #"(?im)^\s*Current working directory:\s*(.+)$"#,
            #"(?im)^\s*Workspace root folder:\s*(.+)$"#,
            #"(?im)^\s*Workspace root:\s*(.+)$"#
        ] {
            guard let range = text.range(of: pattern, options: .regularExpression) else { continue }
            let line = String(text[range])
            guard let value = line.split(separator: ":", maxSplits: 1).last.flatMap({ sanitizeContextPath(String($0)) }) else {
                continue
            }
            return value
        }
        return nil
    }

    private static func sanitizeContextPath(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
        guard !trimmed.isEmpty, trimmed != "." else { return nil }
        let lower = trimmed.lowercased()
        guard lower != "undefined", lower != "null" else { return nil }
        return trimmed
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
        remembered: inout [String: ResponseToolCallMemory],
        tools: [OpenAIToolSpec] = []
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
                    transcript.append("LOCAL TOOL RESULT: \(toolResultFeedback(toolCallID: callID, toolName: toolName, text: output, remembered: remembered, tools: tools))")
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
                let result = appendResponsesInput(item, to: &transcript, remembered: &remembered, tools: tools)
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

    private static func appendToolInventory(_ transcript: inout [String], tools: [OpenAIToolSpec], toolChoice: Any?, context: ToolCallContext?) {
        guard !tools.isEmpty else { return }
        transcript.append("")
        transcript.append("LOCAL TOOL INVENTORY:")
        transcript.append("Client tool targets: \(tools.map(\.name).joined(separator: ", "))")
        transcript.append("These are client execution targets, not the names you should emit.")
        transcript.append("For local work, emit only SDK tool names from the SDK TOOL ROUTING MAP. The adapter forwards those SDK calls to the matching client tool names and schemas.")
        transcript.append("Prefer built-in SDK routes for shell/read/write/edit/glob/grep/ls-style client tools. Use SDK mcp for unique client tools and MCP/server tools.")
        transcript.append("When the user names a specific allowed client tool, use the matching SDK TOOL ROUTING MAP route and do not substitute a different tool.")
        transcript.append("If you need a local tool, emit the tool call before prose. Do not write progress text such as \"creating the file\" instead of calling a tool.")
        if hasCompatibleTool("shell", in: tools) {
            transcript.append("A shell client tool is available. For general file creation or overwrite requests, prefer an SDK shell call using mkdir -p and a quoted heredoc.")
        }
        for tool in tools {
            let record = toolInventoryRecord(tool)
            if let data = try? JSONSerialization.data(withJSONObject: record, options: [.withoutEscapingSlashes]),
               let json = String(data: data, encoding: .utf8) {
                transcript.append(json)
            }
        }
        appendSDKRoutingMap(&transcript, tools: tools, context: context)
        if let name = toolChoiceFunctionName(toolChoice) {
            transcript.append(requestedToolHint(for: name))
        } else if (toolChoice as? String) == "required" {
            transcript.append("You must call at least one tool.")
        }
    }

    private static func appendSDKRoutingMap(_ transcript: inout [String], tools: [OpenAIToolSpec], context: ToolCallContext?) {
        let routes = sdkRoutingRecords(tools: tools, context: context)
        guard !routes.isEmpty else { return }
        transcript.append("SDK TOOL ROUTING MAP:")
        transcript.append("Use these SDK tool names; the adapter forwards them to the listed client tool and argument shape.")
        for route in routes {
            if let data = try? JSONSerialization.data(withJSONObject: route, options: [.withoutEscapingSlashes]),
               let json = String(data: data, encoding: .utf8) {
                transcript.append(json)
            }
        }
    }

    private static func sdkRoutingRecords(tools: [OpenAIToolSpec], context: ToolCallContext?) -> [[String: Any]] {
        var routes: [[String: Any]] = []
        for sample in sdkRoutingSamples() {
            guard let resolved = resolveToolCall(sample, tools: tools, context: context) else { continue }
            routes.append([
                "sdk": sample.name,
                "client": resolved.name,
                "clientArgs": resolved.arguments.mapValues(\.foundationValue)
            ])
        }
        for tool in tools {
            guard let target = mcpTarget(forClientToolName: tool.name, includeMapped: false) else { continue }
            routes.append([
                "sdk": "mcp",
                "client": tool.name,
                "sdkArgs": [
                    "providerIdentifier": target.provider,
                    "toolName": target.toolName,
                    "args": "match client schema"
                ]
            ])
        }
        return Array(routes.prefix(24))
    }

    private static func sdkRoutingSamples() -> [CursorToolCall] {
        [
            CursorToolCall(name: "shell", arguments: ["command": .string("<command>"), "workingDirectory": .string("/workspace"), "timeout": .number(120_000)]),
            CursorToolCall(name: "read", arguments: ["path": .string("src/App.tsx"), "offset": .number(1), "limit": .number(80)]),
            CursorToolCall(name: "write", arguments: ["path": .string("src/App.tsx"), "fileText": .string("<file content>")]),
            CursorToolCall(name: "edit", arguments: ["path": .string("src/App.tsx"), "oldString": .string("<old text>"), "newString": .string("<new text>")]),
            CursorToolCall(name: "delete", arguments: ["path": .string("src/old.tsx")]),
            CursorToolCall(name: "glob", arguments: ["targetDirectory": .string("."), "globPattern": .string("**/*")]),
            CursorToolCall(name: "grep", arguments: ["pattern": .string("<pattern>"), "path": .string("."), "glob": .string("*")]),
            CursorToolCall(name: "ls", arguments: ["path": .string(".")]),
            CursorToolCall(name: "readLints", arguments: ["paths": .array([.string("src/App.tsx")])]),
            CursorToolCall(name: "semSearch", arguments: ["query": .string("<query>"), "targetDirectories": .array([.string(".")])]),
            CursorToolCall(name: "todowrite", arguments: [
                "todos": .array([.object(["content": .string("<task>"), "status": .string("in_progress"), "priority": .string("medium")])])
            ])
        ]
    }

    private static func toolInventoryRecord(_ tool: OpenAIToolSpec) -> [String: Any] {
        var record: [String: Any] = ["name": tool.name]
        if let description = tool.description { record["description"] = description }
        if let parameters = tool.parameters { record["parameters"] = parameters.foundationValue }
        if let target = mcpTarget(forClientToolName: tool.name, includeMapped: false) {
            record["sdk_mcp"] = [
                "providerIdentifier": target.provider,
                "toolName": target.toolName,
                "args": "match this tool schema"
            ]
        }
        return record
    }

    private static func appendRequiredLocalToolHint(_ transcript: inout [String], tools: [OpenAIToolSpec], latestUserText: String) {
        transcript.append("")
        transcript.append("LOCAL TOOL REQUIRED FOR THE LATEST USER REQUEST:")
        transcript.append("The latest user request requires local filesystem or shell execution. Emit exactly one SDK tool call next and no prose.")
        if let requestedTool = explicitlyRequestedToolName(in: latestUserText, tools: tools) {
            transcript.append("\(requestedToolHint(for: requestedTool)) After the client returns a LOCAL TOOL RESULT, continue.")
            return
        }
        if hasCompatibleTool("shell", in: tools) {
            transcript.append("Use SDK shell when it maps to the client shell/bash tool. For unique shell-like client tools, use the SDK mcp route. For creating or overwriting a file, run mkdir -p for the parent directory and write the file with a single quoted heredoc. After the client returns a LOCAL TOOL RESULT, continue.")
        } else {
            transcript.append("For creating or overwriting a file, use SDK write when it maps to the client write tool. For unique writer tools, use the SDK mcp route with matching arguments. After the client returns a LOCAL TOOL RESULT, continue.")
        }
    }

    private static func requestedToolHint(for toolName: String) -> String {
        if canonicalToolName(toolName) == "glob", normalizedName(toolName) != "glob" {
            return "Use SDK glob now; it will be forwarded to client tool \(toolName) with arguments matching its schema. Do not substitute shell or prose for this explicitly requested client tool."
        }
        let canonical = canonicalToolName(toolName)
        if isKnownMappedToolName(toolName) {
            return "Use SDK \(canonical) now; it will be forwarded to client tool \(toolName) with arguments matching its schema. Do not substitute a different tool."
        }
        if let mcpTarget = mcpTarget(forClientToolName: toolName, includeMapped: false) {
            return "Use SDK mcp now with providerIdentifier \"\(mcpTarget.provider)\", toolName \"\(mcpTarget.toolName)\", and args matching the \(toolName) schema. Do not use SDK shell/write as a substitute for this explicitly requested client tool."
        }
        return "Use SDK mcp now with providerIdentifier \"client\", toolName \"\(toolName)\", and args matching the \(toolName) schema. Do not substitute a different tool."
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

    private static func mcpTarget(forClientToolName name: String, includeMapped: Bool = false) -> (provider: String, toolName: String)? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if isKnownMappedToolName(trimmed) {
            return includeMapped ? (provider: "client", toolName: trimmed) : nil
        }
        if trimmed.hasPrefix("mcp__") {
            let parts = trimmed.components(separatedBy: "__").filter { !$0.isEmpty }
            if parts.count >= 3 {
                return (provider: parts[1], toolName: parts.dropFirst(2).joined(separator: "__"))
            }
        }
        if let separator = trimmed.firstIndex(of: "_"),
           separator != trimmed.startIndex,
           separator < trimmed.index(before: trimmed.endIndex) {
            let provider = String(trimmed[..<separator])
            let toolName = String(trimmed[trimmed.index(after: separator)...])
            guard !provider.isEmpty, !toolName.isEmpty else { return nil }
            return (provider: provider, toolName: toolName)
        }
        return (provider: "client", toolName: trimmed)
    }

    private static func isKnownMappedToolName(_ name: String) -> Bool {
        let knownCanonicals = ["shell", "write", "read", "edit", "delete", "grep", "glob", "ls", "readlints", "mcp", "semsearch", "todowrite"]
        let normalized = normalizedName(name)
        return knownCanonicals.contains { canonical in
            canonicalToolName(name) == canonical || toolAliases(for: canonical).map(normalizedName).contains(normalized)
        }
    }

    private static func shouldRequireLocalTool(for text: String, tools: [OpenAIToolSpec]) -> Bool {
        guard !tools.isEmpty else { return false }
        if explicitlyRequestedToolName(in: text, tools: tools) != nil {
            return true
        }
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
        let wantsProjectScaffold = lower.range(of: #"\b(build|create|make|scaffold|generate|implement|setup|set up)\b"#, options: .regularExpression) != nil
            && lower.range(of: #"\b(app|application|site|website|project|component|page|vite|react|next|vue|svelte|todo|dashboard|cli)\b"#, options: .regularExpression) != nil
        if wantsProjectScaffold, hasAnyCompatibleTool(["write", "shell"], in: tools) {
            return true
        }
        let wantsCommand = lower.range(of: #"\b(run|execute|start|launch)\b"#, options: .regularExpression) != nil
            && (lower.contains("command") || lower.contains("shell") || lower.contains("terminal") || lower.contains("server"))
        return wantsCommand && hasCompatibleTool("shell", in: tools)
    }

    private static func isWorkspaceMutationToolCall(_ toolCall: [String: Any], tools: [OpenAIToolSpec]) -> Bool {
        guard let function = toolCall["function"] as? [String: Any],
              let name = stringValue(function["name"]) else {
            return false
        }
        return isWorkspaceMutationToolCall(name: name, arguments: jsonArguments(from: function["arguments"]), tools: tools)
    }

    private static func hasResponseWorkspaceMutationToolCallAfterLatestUser(_ input: Any?, tools: [OpenAIToolSpec]) -> Bool {
        guard let items = input as? [Any] else { return false }
        var sawLatestUser = false
        var mutationAfterLatestUser = false
        var latestUserText = ""
        for item in items {
            if let text = item as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sawLatestUser = true
                mutationAfterLatestUser = false
                latestUserText = text
                continue
            }
            guard let object = item as? [String: Any] else { continue }
            let type = (object["type"] as? String) ?? ""
            if type == "function_call" {
                let requestedTool = explicitlyRequestedToolName(in: latestUserText, tools: tools)
                if sawLatestUser,
                   let name = stringValue(object["name"]),
                   (isWorkspaceMutationToolCall(name: name, arguments: jsonArguments(from: object["arguments"]), tools: tools)
                       || requestedTool.map { toolCallMatchesClientTool(name: name, arguments: jsonArguments(from: object["arguments"]), requestedTool: $0, tools: tools) } == true) {
                    mutationAfterLatestUser = true
                }
                continue
            }
            if type == "message" || object["role"] != nil {
                let role = (object["role"] as? String) ?? "user"
                let text = contentText(object["content"], role: role)
                if role == "user", !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    sawLatestUser = true
                    mutationAfterLatestUser = false
                    latestUserText = text
                }
            }
        }
        return mutationAfterLatestUser
    }

    private static func isSpecificToolCall(_ toolCall: [String: Any], requestedTool: String, tools: [OpenAIToolSpec]) -> Bool {
        guard let function = toolCall["function"] as? [String: Any],
              let name = stringValue(function["name"]) else {
            return false
        }
        return toolCallMatchesClientTool(name: name, arguments: jsonArguments(from: function["arguments"]), requestedTool: requestedTool, tools: tools)
    }

    private static func toolCallMatchesClientTool(name: String, arguments: [String: JSONValue], requestedTool: String, tools: [OpenAIToolSpec]) -> Bool {
        if normalizedName(name) == normalizedName(requestedTool) {
            return true
        }
        return resolveToolSpec(name, arguments: arguments, tools: tools).map { normalizedName($0.name) == normalizedName(requestedTool) } ?? false
    }

    private static func isWorkspaceMutationToolCall(name: String, arguments: [String: JSONValue], tools: [OpenAIToolSpec]) -> Bool {
        let canonical = canonicalToolName(name)
        if ["write", "edit", "delete"].contains(canonical) {
            return true
        }
        if canonical == "shell" {
            guard let command = firstStringArgument(inRecords: arguments, keys: ["command", "cmd", "script", "input"]) else {
                return false
            }
            return isFileMutatingShellCommand(command)
        }

        guard let tool = resolveToolSpec(name, arguments: arguments, tools: tools) else {
            return false
        }
        if schemaLooksCompatible(sdkToolName: "shell", tool: tool),
           let command = firstStringArgument(inRecords: arguments, keys: ["command", "cmd", "script", "input"]),
           isFileMutatingShellCommand(command) {
            return true
        }
        if (schemaLooksCompatible(sdkToolName: "write", tool: tool)
            || schemaLooksCompatible(sdkToolName: "edit", tool: tool)
            || schemaLooksCompatible(sdkToolName: "delete", tool: tool)),
           looksLikeWorkspaceMutationArguments(arguments) {
            return true
        }
        return false
    }

    private static func jsonArguments(from value: Any?) -> [String: JSONValue] {
        if let object = value as? [String: Any] {
            return object.mapValues(JSONValue.from)
        }
        guard let string = value as? String,
              let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object.mapValues(JSONValue.from)
    }

    private static func argumentRecords(_ arguments: [String: JSONValue], depth: Int = 0) -> [[String: JSONValue]] {
        guard depth <= 3 else { return [arguments] }
        var records = [arguments]
        for key in wrapperObjectPropertyAliases() {
            guard let nested = firstArgument(in: arguments, keys: [key])?.value,
                  let object = objectArgumentValue(nested) else {
                continue
            }
            records.append(contentsOf: argumentRecords(object, depth: depth + 1))
        }
        return records
    }

    private static func firstStringArgument(inRecords arguments: [String: JSONValue], keys: [String]) -> String? {
        for record in argumentRecords(arguments) {
            if let value = firstArgument(in: record, keys: keys)?.value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func looksLikeWorkspaceMutationArguments(_ arguments: [String: JSONValue]) -> Bool {
        for record in argumentRecords(arguments) {
            if firstArgument(in: record, keys: ["patchContent", "patch_content", "patch", "diff", "unifiedDiff", "unified_diff"])?.value.stringValue != nil {
                return true
            }
            let path = firstArgument(in: record, keys: pathPropertyAliases() + ["target_file", "targetFile"])?.value
            let hasPath = path.map(shouldIncludeOptionalPath) ?? false
            guard hasPath else { continue }

            let operation = firstArgument(in: record, keys: operationPropertyAliases())?.value.stringValue
            let normalizedOperation = operation.map(normalizedName) ?? ""
            let mutatingOperations = Set(["write", "create", "overwrite", "replace", "edit", "update", "delete", "remove", "strreplace"])
            let mutatingOperation = mutatingOperations.contains(normalizedOperation)

            let content = firstArgument(
                in: record,
                keys: ["fileText", "file_text", "content", "contents", "text", "fileContent", "file_content", "streamContent", "stream_content"]
            )?.value.stringValue
            let oldText = firstArgument(
                in: record,
                keys: ["oldString", "old_string", "old_str", "oldText", "old_text", "search", "searchString", "search_string"]
            )?.value.stringValue
            let newText = firstArgument(
                in: record,
                keys: ["newString", "new_string", "new_str", "newText", "new_text", "replacement", "replace"]
            )?.value.stringValue

            if content != nil, operation == nil || mutatingOperation {
                return true
            }
            if oldText != nil, newText != nil, operation == nil || mutatingOperation {
                return true
            }
            if ["delete", "remove"].contains(normalizedOperation) {
                return true
            }
        }
        return false
    }

    private static func isFileMutatingShellCommand(_ command: String) -> Bool {
        let text = command.lowercased()
        let patterns = [
            #"(^|[\s;&|])(?:cat|printf|echo)\b[\s\S]*(?:>|>>|<<)"#,
            #"(?:^|[\s;&|])(?:tee|touch|cp|mv|rm)\b"#,
            #"(?:^|[\s;&|])sed\b[^\n]*(?:\s-i\b|\s-i['"]?\s)"#,
            #"(?:^|[\s;&|])perl\b[^\n]*(?:\s-pi\b|\s-pi['"]?\s)"#,
            #"(?:^|[\s;&|])(?:npm|pnpm|yarn|bun)\s+(?:init|install|add|create)\b"#,
            #"(?:>|>>)\s*(?:\.{0,2}/)?[a-z0-9._/-]+"#
        ]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    private static func hasAnyCompatibleTool(_ canonicalNames: [String], in tools: [OpenAIToolSpec]) -> Bool {
        canonicalNames.contains { hasCompatibleTool($0, in: tools) }
    }

    private static func hasCompatibleTool(_ canonicalName: String, in tools: [OpenAIToolSpec]) -> Bool {
        let aliases = Set(toolAliases(for: canonicalName).map(normalizedName))
        return tools.contains { tool in
            aliases.contains(normalizedName(tool.name)) || schemaLooksCompatible(sdkToolName: canonicalName, tool: tool)
        }
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
            let sdkMemory = sdkToolCallMemory.memory(id: id)
            remembered[id] = ResponseToolCallMemory(
                name: name,
                arguments: args,
                sdkName: sdkMemory?.name,
                sdkArguments: sdkMemory?.arguments
            )
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
        remembered: [String: ResponseToolCallMemory],
        tools: [OpenAIToolSpec] = []
    ) -> String {
        let rememberedCall = remembered[toolCallID]
        let registeredSDKCall = sdkToolCallMemory.memory(id: toolCallID)
        let clientToolName = toolName.isEmpty ? rememberedCall?.name ?? "" : toolName
        let arguments = rememberedCall?.arguments ?? [:]
        let tool = toolSpec(named: clientToolName, in: tools)
        let sdkToolName = rememberedCall?.sdkName
            ?? registeredSDKCall?.name
            ?? sdkCanonical(fromToolCallID: toolCallID)
            ?? sdkFeedbackToolName(for: clientToolName, arguments: arguments, tool: tool)
        let sdkArguments = rememberedCall?.sdkArguments
            ?? registeredSDKCall?.arguments
            ?? sdkFeedbackArguments(for: clientToolName, arguments: arguments, tool: tool, sdkToolName: sdkToolName)
        let record: [String: Any] = [
            "toolCallId": toolCallID,
            "toolName": sdkToolName,
            "arguments": sdkArguments.mapValues(\.foundationValue),
            "result": text
        ]
        let data = (try? JSONSerialization.data(withJSONObject: record, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func sdkCanonical(fromToolCallID toolCallID: String) -> String? {
        let parts = toolCallID.split(separator: "_").map(String.init)
        guard parts.count >= 2,
              Int(parts.last ?? "") != nil else {
            return nil
        }
        let canonical = parts[parts.count - 2].lowercased()
        return isKnownSDKCanonical(canonical) ? canonical : nil
    }

    private static func toolSpec(named name: String, in tools: [OpenAIToolSpec]) -> OpenAIToolSpec? {
        let normalized = normalizedName(name)
        return tools.first { normalizedName($0.name) == normalized }
    }

    private static func sdkFeedbackToolName(for clientToolName: String, arguments: [String: JSONValue] = [:], tool: OpenAIToolSpec? = nil) -> String {
        let canonical = canonicalToolName(clientToolName)
        if isKnownSDKCanonical(canonical) {
            return canonical
        }
        if explicitMCPTarget(forClientToolName: clientToolName) != nil {
            return "mcp"
        }
        if let inferred = inferSDKCanonicalFromClientTool(arguments: arguments, tool: tool) {
            return inferred
        }
        if mcpTarget(forClientToolName: clientToolName) != nil {
            return "mcp"
        }
        return clientToolName
    }

    private static func explicitMCPTarget(forClientToolName name: String) -> (provider: String, toolName: String)? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("mcp__") else { return nil }
        return mcpTarget(forClientToolName: trimmed)
    }

    private static func inferSDKCanonicalFromClientTool(arguments: [String: JSONValue], tool: OpenAIToolSpec?) -> String? {
        let operation = firstArgument(in: arguments, keys: operationPropertyAliases())?.value.stringValue
        switch normalizedName(operation ?? "") {
        case "write", "create", "overwrite":
            return "write"
        case "replace", "strreplace", "edit", "update":
            return "edit"
        case "read", "view", "open":
            return "read"
        case "delete", "remove":
            return "delete"
        default:
            break
        }

        guard let tool else { return nil }
        if schemaLooksCompatible(sdkToolName: "shell", tool: tool),
           firstArgument(in: arguments, keys: shellCommandAliases())?.value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return "shell"
        }
        if schemaLooksCompatible(sdkToolName: "edit", tool: tool),
           firstArgument(in: arguments, keys: oldTextAliases()) != nil,
           firstArgument(in: arguments, keys: newTextAliases()) != nil {
            return "edit"
        }
        if schemaLooksCompatible(sdkToolName: "write", tool: tool),
           firstArgument(in: arguments, keys: pathPropertyAliases()) != nil,
           firstArgument(in: arguments, keys: fileContentAliases()) != nil {
            return "write"
        }
        if schemaLooksCompatible(sdkToolName: "glob", tool: tool),
           firstArgument(in: arguments, keys: globPatternAliases())?.value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return "glob"
        }
        if schemaLooksCompatible(sdkToolName: "grep", tool: tool),
           firstArgument(in: arguments, keys: ["pattern", "query", "search", "regex", "searchPattern", "search_pattern"])?.value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return "grep"
        }
        if schemaLooksCompatible(sdkToolName: "ls", tool: tool),
           firstArgument(in: arguments, keys: pathPropertyAliases() + ["directory", "dir"]) != nil {
            return "ls"
        }
        return nil
    }

    private static func sdkFeedbackArguments(for clientToolName: String, arguments: [String: JSONValue], tool: OpenAIToolSpec? = nil, sdkToolName: String? = nil) -> [String: JSONValue] {
        let canonical = sdkToolName.flatMap { isKnownSDKCanonical($0) ? $0 : nil }
            ?? sdkFeedbackToolName(for: clientToolName, arguments: arguments, tool: tool)
        if canonical == "mcp", let target = mcpTarget(forClientToolName: clientToolName, includeMapped: true) {
            return [
                "providerIdentifier": .string(target.provider),
                "toolName": .string(target.toolName),
                "args": .object(arguments)
            ]
        }
        switch canonical {
        case "shell":
            return compactJSON([
                "command": firstArgument(in: arguments, keys: shellCommandAliases())?.value,
                "workingDirectory": firstArgument(in: arguments, keys: shellWorkdirAliases())?.value,
                "timeout": sdkTimeoutArgument(firstArgument(in: arguments, keys: ["timeout", "timeoutMs", "timeout_ms", "timeoutSeconds", "timeout_seconds"]), tool: tool)
            ])
        case "write":
            return compactJSON([
                "path": firstArgument(in: arguments, keys: pathPropertyAliases())?.value,
                "fileText": firstArgument(in: arguments, keys: fileContentAliases() + newTextAliases())?.value
            ])
        case "read":
            return compactJSON([
                "path": firstArgument(in: arguments, keys: pathPropertyAliases() + ["directory"])?.value,
                "offset": firstArgument(in: arguments, keys: ["offset", "start", "startLine", "start_line"])?.value,
                "limit": firstArgument(in: arguments, keys: ["limit", "maxLines", "max_lines", "lineCount", "line_count"])?.value
            ])
        case "delete":
            return compactJSON([
                "path": firstArgument(in: arguments, keys: pathPropertyAliases() + ["directory"])?.value
            ])
        case "edit":
            return compactJSON([
                "path": firstArgument(in: arguments, keys: pathPropertyAliases() + ["directory"])?.value,
                "oldString": firstArgument(in: arguments, keys: oldTextAliases())?.value,
                "newString": firstArgument(in: arguments, keys: newTextAliases())?.value
            ])
        case "glob":
            return compactJSON([
                "targetDirectory": firstArgument(in: arguments, keys: globPathAliases())?.value,
                "globPattern": firstArgument(in: arguments, keys: globPatternAliases())?.value
            ])
        case "grep":
            return compactJSON([
                "pattern": firstArgument(in: arguments, keys: ["pattern", "query", "search", "regex"])?.value,
                "path": firstArgument(in: arguments, keys: pathPropertyAliases() + ["directory", "cwd"])?.value,
                "glob": firstArgument(in: arguments, keys: ["glob", "include"])?.value,
                "caseInsensitive": firstArgument(in: arguments, keys: ["caseInsensitive", "case_insensitive", "ignoreCase", "ignore_case"])?.value,
                "literal": firstArgument(in: arguments, keys: ["literal", "fixedString", "fixed_string"])?.value,
                "context": firstArgument(in: arguments, keys: ["context", "contextLines", "context_lines"])?.value,
                "headLimit": firstArgument(in: arguments, keys: ["headLimit", "head_limit", "limit", "maxResults", "max_results"])?.value
            ])
        case "ls":
            return compactJSON([
                "path": firstArgument(in: arguments, keys: pathPropertyAliases() + ["directory", "dir"])?.value,
                "limit": firstArgument(in: arguments, keys: ["limit", "maxResults", "max_results"])?.value
            ])
        default:
            return arguments
        }
    }

    private static func sdkTimeoutArgument(_ argument: NamedArgument?, tool: OpenAIToolSpec?) -> JSONValue? {
        guard let argument else { return nil }
        guard case .number(let number) = argument.value else { return argument.value }
        let source = normalizedName(argument.key)
        if ["timeoutms", "timeoutmilliseconds", "milliseconds"].contains(source) {
            return .number(number)
        }
        if ["timeoutseconds", "seconds"].contains(source) {
            return .number(number * 1000)
        }
        guard let tool else {
            return .number(number)
        }
        let properties = parameterPropertyNames(tool)
        let target = propertyName(matching: ["timeout", "timeoutMs", "timeout_ms", "timeoutSeconds", "timeout_seconds"], in: properties) ?? argument.key
        return toolPropertyPrefersSecondsTimeout(tool: tool, property: target) ? .number(number * 1000) : .number(number)
    }

    private static func compactJSON(_ values: [String: JSONValue?]) -> [String: JSONValue] {
        var output: [String: JSONValue] = [:]
        for (key, value) in values {
            if let value {
                output[key] = value
            }
        }
        return output
    }

    static func canMapToolCall(_ toolCall: CursorToolCall, tools: [OpenAIToolSpec], context: ToolCallContext? = nil) -> Bool {
        resolveToolCall(toolCall, tools: tools, context: context) != nil
    }

    static func toolCallRetryHint(_ toolCall: CursorToolCall, tools: [OpenAIToolSpec], context: ToolCallContext? = nil) -> String {
        let normalizedToolCall = normalizeSDKToolCall(toolCall)
        guard let tool = resolveToolSpec(normalizedToolCall.name, arguments: normalizedToolCall.arguments, tools: tools, context: context) else {
            if tools.isEmpty {
                return "No client tool inventory was available for SDK \(normalizedToolCall.name)."
            }
            return "SDK \(normalizedToolCall.name) did not match any client tool. Available client tools: \(tools.map(\.name).joined(separator: ", "))."
        }
        let arguments = normalizeArguments(normalizedToolCall.arguments, sdkToolName: normalizedToolCall.name, tool: tool, context: context)
        if toolArgumentsSatisfySchema(arguments, tool: tool) {
            return "SDK \(normalizedToolCall.name) maps to client \(tool.name); retry with complete arguments for that route."
        }
        return [
            "SDK \(normalizedToolCall.name) mapped to client \(tool.name), but normalized arguments do not satisfy the client JSON schema.",
            "Normalized arguments: \(safeJSONForPrompt(arguments.mapValues(\.foundationValue))).",
            "Required client arguments: \(toolRequiredArgumentSummary(tool)).",
            "Client schema properties: \(toolSchemaPropertySummary(tool))."
        ].joined(separator: " ")
    }

    private static func toOpenAIToolCalls(_ toolCalls: [CursorToolCall], tools: [OpenAIToolSpec], responseID: String, context: ToolCallContext? = nil) -> [[String: Any]] {
        toolCalls.enumerated().compactMap { index, toolCall in
            guard let resolved = resolveToolCall(toolCall, tools: tools, context: context) else {
                return nil
            }
            let normalizedToolCall = normalizeSDKToolCall(toolCall)
            let sdkCanonical = canonicalToolName(normalizedToolCall.name)
            let id = "call_\(responseID.replacingOccurrences(of: "[^A-Za-z0-9]", with: "", options: .regularExpression).suffix(18))_\(sdkCanonical)_\(index)"
            sdkToolCallMemory.remember(id: id, name: sdkCanonical, arguments: normalizedToolCall.arguments)
            return [
                "id": id,
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
        guard let resolved = resolveToolCall(toolCall, tools: prepared.tools, context: prepared.toolContext) else {
            return nil
        }
        let suffix = responseID.replacingOccurrences(of: "[^A-Za-z0-9]", with: "", options: .regularExpression).suffix(18)
        let normalizedToolCall = normalizeSDKToolCall(toolCall)
        let sdkCanonical = canonicalToolName(normalizedToolCall.name)
        let callID = "call_\(suffix)_\(sdkCanonical)_\(index)"
        sdkToolCallMemory.remember(id: callID, name: sdkCanonical, arguments: normalizedToolCall.arguments)
        return [
            "id": "fc_\(suffix)_\(index)",
            "type": "function_call",
            "call_id": callID,
            "name": resolved.name,
            "arguments": jsonString(resolved.arguments.mapValues(\.foundationValue)),
            "status": "completed"
        ]
    }

    private struct ResolvedToolCall {
        var name: String
        var arguments: [String: JSONValue]
    }

    private static func resolveToolCall(_ toolCall: CursorToolCall, tools: [OpenAIToolSpec], context: ToolCallContext? = nil) -> ResolvedToolCall? {
        let normalizedToolCall = normalizeSDKToolCall(toolCall)
        guard let tool = resolveToolSpec(normalizedToolCall.name, arguments: normalizedToolCall.arguments, tools: tools, context: context) else {
            guard tools.isEmpty else { return nil }
            return ResolvedToolCall(name: normalizedToolCall.name, arguments: normalizedToolCall.arguments)
        }
        let arguments = normalizeArguments(normalizedToolCall.arguments, sdkToolName: normalizedToolCall.name, tool: tool, context: context)
        guard toolArgumentsSatisfySchema(arguments, tool: tool) else { return nil }
        return ResolvedToolCall(
            name: tool.name,
            arguments: arguments
        )
    }

    private static func normalizeSDKToolCall(_ toolCall: CursorToolCall) -> CursorToolCall {
        guard canonicalToolName(toolCall.name) == "edit",
              let streamContent = firstArgument(in: toolCall.arguments, keys: ["streamContent", "stream_content"])?.value,
              let path = firstArgument(in: toolCall.arguments, keys: pathPropertyAliases() + ["target_file", "targetFile"])?.value,
              shouldIncludeOptionalPath(path) else {
            return toolCall
        }

        var arguments = toolCall.arguments
        arguments["streamContent"] = nil
        arguments["stream_content"] = nil
        arguments["path"] = path
        arguments["fileText"] = streamContent
        return CursorToolCall(name: "write", arguments: arguments)
    }

    private static func resolveToolSpec(_ name: String, arguments: [String: JSONValue], tools: [OpenAIToolSpec], context: ToolCallContext? = nil) -> OpenAIToolSpec? {
        if let exact = tools.first(where: { $0.name == name && nameMatchedToolCanAccept(sdkToolName: name, tool: $0) }) { return exact }
        let normalized = normalizedName(name)
        if let caseInsensitive = tools.first(where: { normalizedName($0.name) == normalized && nameMatchedToolCanAccept(sdkToolName: name, tool: $0) }) {
            return caseInsensitive
        }

        if canonicalToolName(name) == "mcp",
           let mcpTool = resolveSpecificMCPTool(arguments: arguments, tools: tools, context: context) {
            return mcpTool
        }

        let aliases = Set(toolAliases(for: name).map(normalizedName))
        if let aliased = tools.first(where: { aliases.contains(normalizedName($0.name)) && schemaLooksCompatible(sdkToolName: name, tool: $0) }) {
            return aliased
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

    private static func nameMatchedToolCanAccept(sdkToolName: String, tool: OpenAIToolSpec) -> Bool {
        guard isKnownSDKCanonical(canonicalToolName(sdkToolName)) else { return true }
        guard !parameterPropertyNames(tool).isEmpty else { return true }
        return schemaLooksCompatible(sdkToolName: sdkToolName, tool: tool)
    }

    private static let knownSDKCanonicalTools: Set<String> = [
        "shell",
        "write",
        "read",
        "edit",
        "delete",
        "grep",
        "glob",
        "ls",
        "readlints",
        "mcp",
        "semsearch",
        "todowrite"
    ]

    private static func isKnownSDKCanonical(_ name: String) -> Bool {
        knownSDKCanonicalTools.contains(name)
    }

    private static func resolveSpecificMCPTool(arguments: [String: JSONValue], tools: [OpenAIToolSpec], context: ToolCallContext? = nil) -> OpenAIToolSpec? {
        let candidates = specificMCPToolNameCandidates(arguments: arguments)
        guard !candidates.isEmpty else { return nil }
        let payload = mcpPayloadArguments(arguments)
        let nestedSDKToolName = mcpNestedSDKToolName(arguments, fallback: "mcp")
        return tools
            .compactMap { tool -> (tool: OpenAIToolSpec, score: Int)? in
                guard let nameScore = mcpToolNameMatchScore(tool.name, candidates: candidates) else {
                    return nil
                }
                let normalized = finalizedToolArguments(
                    specificMCPToolArguments(arguments, tool: tool, context: context),
                    source: payload,
                    sdkToolName: nestedSDKToolName,
                    tool: tool,
                    context: context
                )
                let schemaScore = toolArgumentsSatisfySchema(normalized, tool: tool) ? 10_000 : 0
                return (tool, schemaScore + nameScore)
            }
            .max(by: { $0.score < $1.score })?
            .tool
    }

    private static func mcpToolNameMatchScore(_ toolName: String, candidates: [String]) -> Int? {
        let normalizedTool = normalizedName(toolName)
        var best: Int?
        for candidate in candidates {
            let normalizedCandidate = normalizedName(candidate)
            guard !normalizedCandidate.isEmpty else { continue }
            let score: Int?
            if normalizedTool == normalizedCandidate {
                score = 1_000 + normalizedCandidate.count
            } else if normalizedTool.hasSuffix(normalizedCandidate) {
                score = 100 + normalizedCandidate.count
            } else {
                score = nil
            }
            if let score {
                best = max(best ?? 0, score)
            }
        }
        return best
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
        tool: OpenAIToolSpec,
        wrapperDepth: Int = 0,
        context: ToolCallContext? = nil
    ) -> [String: JSONValue] {
        let canonical = canonicalToolName(sdkToolName)
        let arguments = canonical == "mcp" ? rawArguments : expandedToolArguments(rawArguments)
        let properties = parameterPropertyNames(tool)
        let selectedTool = normalizedName(tool.name)
        let selectedCanonical = canonicalToolName(tool.name)

        if wrapperDepth <= 1,
           let wrapper = wrapperObjectArgumentProperty(tool: tool, properties: properties),
           !(canonical == "mcp" && isMCPWrapperTool(properties: properties)) {
            let nestedTool = OpenAIToolSpec(name: tool.name, description: tool.description, parameters: wrapper.schema)
            let output: [String: JSONValue] = [
                wrapper.key: .object(normalizeArguments(arguments, sdkToolName: sdkToolName, tool: nestedTool, wrapperDepth: wrapperDepth + 1, context: context))
            ]
            return finalizedToolArguments(output, source: arguments, sdkToolName: sdkToolName, tool: tool, context: context)
        }

        if selectedTool == "strreplaceeditor",
           ["write", "read", "edit"].contains(canonical) {
            return strReplaceEditorArguments(arguments, sdkToolName: sdkToolName, properties: properties)
        }

        guard !properties.isEmpty else { return arguments }

        if let commandStyleFile = commandStyleFileArguments(arguments, sdkToolName: sdkToolName, tool: tool, properties: properties, context: context) {
            return finalizedToolArguments(commandStyleFile, source: arguments, sdkToolName: sdkToolName, tool: tool, context: context)
        }
        if let patchStyleFile = patchStyleFileArguments(arguments, sdkToolName: sdkToolName, tool: tool, properties: properties, context: context) {
            return finalizedToolArguments(patchStyleFile, source: arguments, sdkToolName: sdkToolName, tool: tool, context: context)
        }

        var output: [String: JSONValue] = [:]
        var consumed = Set<String>()
        let required = requiredParameterNames(tool)
        let allowAdditionalProperties = parameterAllowsAdditionalProperties(tool)

        if canonical != "shell", selectedCanonical == "shell" {
            return finalizedToolArguments(shellFallbackArguments(arguments, sdkToolName: sdkToolName, tool: tool), source: arguments, sdkToolName: sdkToolName, tool: tool, context: context)
        }

        if canonical == "ls", selectedCanonical == "glob" {
            return finalizedToolArguments(listAsGlobArguments(arguments, tool: tool, context: context), source: arguments, sdkToolName: sdkToolName, tool: tool, context: context)
        }

        if canonical == "mcp", selectedCanonical != "mcp" {
            let payload = mcpPayloadArguments(arguments)
            return finalizedToolArguments(
                specificMCPToolArguments(arguments, tool: tool, context: context),
                source: payload,
                sdkToolName: mcpNestedSDKToolName(arguments, fallback: sdkToolName),
                tool: tool,
                context: context
            )
        }

        func copy(_ source: String, as candidates: [String]) {
            guard let value = arguments[source] else { return }
            guard let target = propertyName(matching: [source] + candidates, in: properties) else {
                consumed.insert(source)
                return
            }
            output[target] = normalizeToolArgumentValue(value, property: target, tool: tool, context: context, sourceProperty: source)
            consumed.insert(source)
        }

        func copyFirst(_ sources: [String], as candidates: [String]) {
            guard let argument = firstArgument(in: arguments, keys: sources) else { return }
            guard let target = propertyName(matching: sources + candidates, in: properties) else {
                consumed.insert(argument.key)
                return
            }
            output[target] = normalizeToolArgumentValue(argument.value, property: target, tool: tool, context: context, sourceProperty: argument.key)
            consumed.insert(argument.key)
        }

        switch canonical {
        case "shell":
            copyFirst(shellCommandAliases(), as: [])
            copyFirst(shellWorkdirAliases(), as: [])
            copyFirst(["timeout", "timeoutMs", "timeout_ms", "timeoutSeconds", "timeout_seconds"], as: [])
            if let descriptionKey = propertyName(matching: ["description"], in: properties),
               output[descriptionKey] == nil {
                let commandKey = propertyName(matching: shellCommandAliases(), in: properties)
                let command = commandKey.flatMap { output[$0]?.stringValue } ?? "shell command"
                output[descriptionKey] = .string(shellToolDescription(for: command))
            }
            fillRequiredShellArguments(&output, source: arguments, properties: properties, required: required, tool: tool)
        case "write":
            copy("path", as: pathPropertyAliases())
            copy("fileText", as: fileContentAliases())
            copy("returnFileContentAfterWrite", as: ["returnFileContent", "return_file_content", "return_file_content_after_write"])
        case "read", "delete":
            copy("path", as: pathPropertyAliases())
            copy("offset", as: ["start", "startLine", "start_line"])
            copy("limit", as: ["maxLines", "max_lines", "lineCount", "line_count"])
            copy("includeLineNumbers", as: ["include_line_numbers", "lineNumbers", "line_numbers"])
        case "edit":
            copy("path", as: pathPropertyAliases())
            copy("oldString", as: oldTextAliases())
            copy("newString", as: newTextAliases())
        case "grep":
            copy("pattern", as: ["query", "regex", "search"])
            copy("path", as: pathPropertyAliases() + ["directory"])
            copy("glob", as: ["include", "includeGlob", "include_glob"])
            copy("outputMode", as: ["output_mode", "mode"])
            copy("literal", as: ["fixedString", "fixed_string"])
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
            let glob = normalizedGlobArguments(arguments, context: context)
            if let patternKey = propertyName(matching: globPatternAliases(), in: properties) {
                let pattern = glob.pattern ?? .string("**/*")
                output[patternKey] = normalizeToolArgumentValue(pattern, property: patternKey, tool: tool, context: context)
            }
            if let searchPath = glob.searchPath,
               shouldIncludeOptionalPath(searchPath),
               let pathKey = propertyName(matching: globPathAliases(), in: properties) {
                output[pathKey] = normalizeToolArgumentValue(searchPath, property: pathKey, tool: tool, context: context)
            } else if let pathKey = propertyName(matching: globPathAliases(), in: properties),
                      isRequired(pathKey, in: required) {
                output[pathKey] = normalizeToolArgumentValue(.string("."), property: pathKey, tool: tool, context: context)
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
            copyFirst(["providerIdentifier", "provider_identifier", "provider", "server", "serverName", "server_name"], as: ["provider", "server", "serverName", "server_name"])
            copyFirst(["toolName", "tool_name", "tool", "name"], as: ["tool", "name", "tool_name"])
            if let payloadArgument = firstArgument(in: arguments, keys: mcpPayloadAliases()),
               let payloadKey = propertyName(matching: mcpPayloadAliases(), in: properties) {
                let payload = objectArgumentValue(payloadArgument.value) ?? [:]
                let nestedSDKToolName = firstArgument(in: arguments, keys: ["toolName", "tool_name", "tool", "name"])?.value.stringValue
                    .map(canonicalToolName) ?? sdkToolName
                if let payloadSchema = parameterPropertySchema(payloadKey, tool: tool) {
                    let nestedTool = OpenAIToolSpec(name: tool.name, description: tool.description, parameters: payloadSchema)
                    let normalizedPayload = normalizedSpecificMCPPayloadArguments(payload, tool: nestedTool, context: context)
                    output[payloadKey] = .object(finalizedToolArguments(
                        normalizedPayload,
                        source: payload,
                        sdkToolName: nestedSDKToolName,
                        tool: nestedTool,
                        context: context
                    ))
                } else {
                    output[payloadKey] = .object(payload)
                }
                consumed.insert(payloadArgument.key)
            }
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
                output[target] = normalizeToolArgumentValue(value, property: target, tool: tool, context: context)
            } else if let target = aliasPropertyName(for: key, toolName: tool.name, properties: properties),
                      output[target] == nil {
                output[target] = normalizeToolArgumentValue(value, property: target, tool: tool, context: context)
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

        if canonical == "shell" {
            sanitizeSyntheticShellWorkdirs(&output, properties: properties, required: required)
        }

        if canonical == "todowrite" {
            output = normalizeTodoWriteArguments(output)
        }

        return finalizedToolArguments(output.isEmpty ? arguments : output, source: arguments, sdkToolName: sdkToolName, tool: tool, context: context)
    }

    private static func finalizedToolArguments(
        _ arguments: [String: JSONValue],
        source: [String: JSONValue],
        sdkToolName: String,
        tool: OpenAIToolSpec,
        context: ToolCallContext?
    ) -> [String: JSONValue] {
        var output = arguments
        fillMissingRequiredSchemaArguments(&output, source: source, sdkToolName: sdkToolName, tool: tool, context: context)
        return output
    }

    private static func fillMissingRequiredSchemaArguments(
        _ output: inout [String: JSONValue],
        source: [String: JSONValue],
        sdkToolName: String,
        tool: OpenAIToolSpec,
        context: ToolCallContext?
    ) {
        let shape = parameterSchemaShape(tool.parameters)
        guard !shape.required.isEmpty else { return }
        for required in shape.required {
            let property = propertyName(matching: [required], in: shape.propertyOrder) ?? required
            let schema = shape.properties[property]
            if argumentValueSatisfiesSchema(output[property], schema: schema, required: true) {
                continue
            }
            if let copied = firstArgument(in: source, keys: [property])?.value,
               argumentValueSatisfiesSchema(copied, schema: schema, required: true) {
                output[property] = normalizeToolArgumentValue(copied, property: property, tool: tool, context: context)
                continue
            }
            guard let synthesized = synthesizedRequiredArgument(
                property: property,
                schema: schema,
                output: output,
                source: source,
                sdkToolName: sdkToolName,
                tool: tool,
                context: context,
                depth: 0
            ) else {
                continue
            }
            let normalized = normalizeToolArgumentValue(synthesized, property: property, tool: tool, context: context)
            if argumentValueSatisfiesSchema(normalized, schema: schema, required: true) {
                output[property] = normalized
            }
        }
    }

    private static func synthesizedRequiredArgument(
        property: String,
        schema: JSONValue?,
        output: [String: JSONValue],
        source: [String: JSONValue],
        sdkToolName: String,
        tool: OpenAIToolSpec,
        context: ToolCallContext?,
        depth: Int
    ) -> JSONValue? {
        guard depth <= 3 else { return nil }
        let canonicalSchema = schemaWithInheritedDefinitions(schema, root: schema)
        guard let object = canonicalParameterSchemaObject(canonicalSchema, root: canonicalSchema, depth: 0, seenRefs: []) else { return nil }
        if let value = object["default"] {
            return value
        }
        if let value = object["const"] {
            return value
        }
        let canonical = canonicalToolName(sdkToolName)
        let normalizedProperty = normalizedName(property)
        let types = schemaJSONTypes(object)
        let hasType: (String) -> Bool = { type in types.isEmpty || types.contains(type) }

        if ["action", "operation", "op", "mode", "tool", "toolname"].contains(normalizedProperty), hasType("string") {
            let value = operationValue(for: canonical, property: property, tool: tool)
            let allowed = stringEnumValues(for: property, tool: tool)
            if allowed.isEmpty || allowed.contains(where: { normalizedName($0) == normalizedName(value) }) {
                return .string(value)
            }
        }
        if case .array(let values)? = object["enum"],
           let first = values.first {
            return first
        }
        if ["description", "desc", "summary", "reason", "explanation"].contains(normalizedProperty), hasType("string") {
            return .string(requiredDescriptionArgument(sdkToolName: sdkToolName, output: output, source: source))
        }
        if ["cwd", "workdir", "workingdirectory"].contains(normalizedProperty), hasType("string") {
            return .string(".")
        }
        if ["timeout", "timeoutms", "timeoutmilliseconds", "timeoutseconds", "seconds"].contains(normalizedProperty),
           hasType("number") || hasType("integer") {
            let timeout = object["minimum"]?.integerValue.map { Double(max(1, $0)) } ?? 120_000
            return .number(timeout)
        }
        if ["limit", "maxresults", "maxlines", "linecount", "headlimit", "count"].contains(normalizedProperty),
           hasType("number") || hasType("integer") {
            return .number(object["minimum"]?.integerValue.map { Double(max(1, $0)) } ?? 200)
        }
        if ["offset", "start", "startline"].contains(normalizedProperty),
           hasType("number") || hasType("integer") {
            return .number(object["minimum"]?.integerValue.map(Double.init) ?? 0)
        }
        if ["caseinsensitive", "ignorecase", "literal", "fixedstring", "recursive", "recurse", "replaceall", "overwrite", "includelinenumbers"].contains(normalizedProperty),
           hasType("boolean") {
            return .bool(false)
        }
        if ["path", "paths", "directory", "directories", "folder", "folders", "dir", "root", "roots", "rootdir", "rootdirs", "basepath", "basepaths", "searchpath", "searchpaths", "targetdirectory", "targetdirectories"].contains(normalizedProperty),
           ["glob", "grep", "ls", "semsearch"].contains(canonical),
           hasType("string") {
            return .string(".")
        }
        if ["pattern", "patterns", "glob", "globs", "globpattern", "globpatterns", "fileglob", "fileglobs", "filepattern", "filepatterns", "includepattern", "includepatterns", "query"].contains(normalizedProperty),
           canonical == "glob",
           hasType("string") {
            return .string("**/*")
        }
        if let arraySchema = preferredArraySchema(object) {
            let minItems = arraySchema["minItems"]?.integerValue ?? 0
            if minItems <= 0 {
                return .array([])
            }
            if let array = synthesizedRequiredArrayArgument(
                property: property,
                schema: arraySchema,
                source: source,
                sdkToolName: sdkToolName,
                tool: tool,
                context: context,
                depth: depth
            ), array.count >= minItems {
                return .array(array)
            }
        }
        if types.contains("object") || object["properties"] != nil || object["required"] != nil {
            return synthesizedObjectArgument(
                schema: object,
                source: source,
                sdkToolName: sdkToolName,
                tool: tool,
                context: context,
                depth: depth + 1
            )
        }
        return nil
    }

    private static func synthesizedRequiredArrayArgument(
        property: String,
        schema: [String: JSONValue],
        source: [String: JSONValue],
        sdkToolName: String,
        tool: OpenAIToolSpec,
        context: ToolCallContext?,
        depth: Int
    ) -> [JSONValue]? {
        let minItems = max(1, schema["minItems"]?.integerValue ?? 1)
        let itemSchema = schemaWithInheritedDefinitions(schema["items"], root: .object(schema))
        var itemTool = tool
        itemTool.parameters = itemSchema
        guard let item = synthesizedRequiredArgument(
            property: property,
            schema: itemSchema,
            output: [:],
            source: source,
            sdkToolName: sdkToolName,
            tool: itemTool,
            context: context,
            depth: depth + 1
        ) else {
            return nil
        }
        return Array(repeating: item, count: minItems)
    }

    private static func synthesizedObjectArgument(
        schema: [String: JSONValue],
        source: [String: JSONValue],
        sdkToolName: String,
        tool: OpenAIToolSpec,
        context: ToolCallContext?,
        depth: Int
    ) -> JSONValue? {
        let properties: [String: JSONValue]
        if case .object(let object)? = schema["properties"] {
            properties = object
        } else {
            properties = [:]
        }
        let required: [String]
        if case .array(let values)? = schema["required"] {
            required = values.compactMap(\.stringValue)
        } else {
            required = []
        }
        guard !properties.isEmpty || required.isEmpty else { return nil }
        var output: [String: JSONValue] = [:]
        let propertyOrder = Array(properties.keys)
        for requiredProperty in required {
            let property = propertyName(matching: [requiredProperty], in: propertyOrder) ?? requiredProperty
            let propertySchema = schemaWithInheritedDefinitions(properties[property], root: .object(schema))
            guard let value = synthesizedRequiredArgument(
                property: property,
                schema: propertySchema,
                output: output,
                source: source,
                sdkToolName: sdkToolName,
                tool: tool,
                context: context,
                depth: depth
            ) else {
                return nil
            }
            output[property] = value
        }
        return .object(output)
    }

    private static func requiredDescriptionArgument(
        sdkToolName: String,
        output: [String: JSONValue],
        source: [String: JSONValue]
    ) -> String {
        let canonical = canonicalToolName(sdkToolName)
        let command = firstArgument(in: output, keys: shellCommandAliases())?.value.stringValue
            ?? firstArgument(in: source, keys: shellCommandAliases())?.value.stringValue
        if canonical == "shell", let command {
            return shellToolDescription(for: command)
        }
        let path = firstArgument(in: output, keys: pathPropertyAliases())?.value.stringValue
            ?? firstArgument(in: source, keys: pathPropertyAliases())?.value.stringValue
        switch canonical {
        case "write":
            return path.map { "Write \($0)" } ?? "Write file"
        case "read":
            return path.map { "Read \($0)" } ?? "Read file"
        case "edit":
            return path.map { "Edit \($0)" } ?? "Edit file"
        case "delete":
            return path.map { "Delete \($0)" } ?? "Delete file"
        case "glob":
            return "Find matching files"
        case "grep":
            return "Search files"
        case "ls":
            return "List files"
        default:
            return "Run local tool"
        }
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

    private static func arrayArgumentValue(_ value: JSONValue) -> [JSONValue]? {
        if case .array(let values) = value {
            return values
        }
        guard let string = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              string.hasPrefix("["),
              let data = string.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return nil
        }
        return array.map(JSONValue.from)
    }

    private static func shellFallbackArguments(
        _ arguments: [String: JSONValue],
        sdkToolName: String,
        tool: OpenAIToolSpec
    ) -> [String: JSONValue] {
        let properties = parameterPropertyNames(tool)
        guard !properties.isEmpty,
              let commandKey = propertyName(matching: shellCommandAliases(), in: properties),
              let command = shellFallbackCommand(arguments, sdkToolName: sdkToolName) else {
            return arguments
        }

        var output: [String: JSONValue] = [commandKey: .string(command)]
        if let workdir = firstArgument(in: arguments, keys: shellExplicitWorkdirAliases())?.value,
           let workdirKey = propertyName(matching: shellExplicitWorkdirAliases(), in: properties),
           shouldIncludeOptionalPath(workdir) {
            output[workdirKey] = workdir
        }
        if let timeoutArgument = firstArgument(in: arguments, keys: ["timeout", "timeoutMs", "timeout_ms", "timeoutSeconds", "timeout_seconds"]),
           let timeoutKey = propertyName(matching: ["timeout", "timeoutMs", "timeout_ms", "timeoutSeconds", "timeout_seconds"], in: properties) {
            output[timeoutKey] = normalizeToolArgumentValue(timeoutArgument.value, property: timeoutKey, tool: tool, context: nil, sourceProperty: timeoutArgument.key)
        }
        if let descriptionKey = propertyName(matching: ["description"], in: properties) {
            output[descriptionKey] = .string(shellToolDescription(for: command))
        }
        fillRequiredShellArguments(&output, source: arguments, properties: properties, required: requiredParameterNames(tool), tool: tool)
        sanitizeSyntheticShellWorkdirs(&output, properties: properties, required: requiredParameterNames(tool))
        return output
    }

    private static func sanitizeSyntheticShellWorkdirs(
        _ output: inout [String: JSONValue],
        properties: [String],
        required: Set<String>
    ) {
        var seen = Set<String>()
        for key in shellExplicitWorkdirAliases() {
            guard let property = propertyName(matching: [key], in: properties),
                  !seen.contains(property),
                  let value = output[property],
                  isSyntheticSDKWorkingDirectory(value) else {
                continue
            }
            seen.insert(property)
            if isRequired(property, in: required) {
                output[property] = .string(".")
            } else {
                output[property] = nil
            }
        }
    }

    private static func isSyntheticSDKWorkingDirectory(_ value: JSONValue) -> Bool {
        guard let string = value.stringValue else { return false }
        switch string.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "", ".", "/workspace", "workspace":
            return true
        default:
            return false
        }
    }

    private static func specificMCPToolArguments(_ arguments: [String: JSONValue], tool: OpenAIToolSpec, context: ToolCallContext? = nil) -> [String: JSONValue] {
        normalizedSpecificMCPPayloadArguments(mcpPayloadArguments(arguments), tool: tool, context: context)
    }

    private static func normalizedSpecificMCPPayloadArguments(_ payload: [String: JSONValue], tool: OpenAIToolSpec, context: ToolCallContext? = nil) -> [String: JSONValue] {
        let properties = parameterPropertyNames(tool)
        let allowAdditionalProperties = parameterAllowsAdditionalProperties(tool)
        guard !properties.isEmpty else {
            return payload
        }
        var output: [String: JSONValue] = [:]
        for (key, value) in expandedToolArguments(payload) {
            if let target = propertyName(matching: [key], in: properties) {
                output[target] = normalizeToolArgumentValue(value, property: target, tool: tool, context: context)
            } else if let target = aliasPropertyName(for: key, toolName: tool.name, properties: properties),
                      output[target] == nil {
                output[target] = normalizeToolArgumentValue(value, property: target, tool: tool, context: context)
            } else if allowAdditionalProperties {
                output[key] = value
            }
        }
        return output
    }

    private static func isMCPWrapperTool(properties: [String]) -> Bool {
        propertyName(matching: ["providerIdentifier", "provider_identifier", "provider", "server", "serverName", "server_name"], in: properties) != nil
            && propertyName(matching: ["toolName", "tool_name", "tool", "name"], in: properties) != nil
            && propertyName(matching: mcpPayloadAliases(), in: properties) != nil
    }

    private static func mcpPayloadArguments(_ arguments: [String: JSONValue]) -> [String: JSONValue] {
        guard let value = firstArgument(in: arguments, keys: mcpPayloadAliases())?.value else {
            return [:]
        }
        return objectArgumentValue(value) ?? [:]
    }

    private static func mcpNestedSDKToolName(_ arguments: [String: JSONValue], fallback: String) -> String {
        firstArgument(in: arguments, keys: ["toolName", "tool_name", "tool", "name"])?.value.stringValue
            .map(canonicalToolName) ?? fallback
    }

    private static func mcpPayloadAliases() -> [String] {
        ["args", "arguments", "input", "params", "parameters", "payload", "data"]
    }

    private static func shellFallbackCommand(_ arguments: [String: JSONValue], sdkToolName: String) -> String? {
        switch canonicalToolName(sdkToolName) {
        case "write":
            guard let path = firstArgument(in: arguments, keys: pathPropertyAliases())?.value.stringValue,
                  let content = firstArgument(in: arguments, keys: fileContentAliases())?.value.stringValue else {
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
        case "edit":
            guard let path = firstArgument(in: arguments, keys: pathPropertyAliases())?.value.stringValue,
                  let oldString = firstArgument(in: arguments, keys: oldTextAliases())?.value.stringValue,
                  !oldString.isEmpty,
                  let newString = firstArgument(in: arguments, keys: newTextAliases())?.value.stringValue else {
                return nil
            }
            let replaceAll: Bool
            if case .bool(true) = firstArgument(in: arguments, keys: ["replaceAll", "replace_all", "replaceAllOccurrences", "replace_all_occurrences"])?.value {
                replaceAll = true
            } else {
                replaceAll = false
            }
            return """
            python3 - <<'PY'
            from pathlib import Path
            path = Path(\(pythonStringLiteral(path)))
            old = \(pythonStringLiteral(oldString))
            new = \(pythonStringLiteral(newString))
            text = path.read_text()
            if old not in text:
                raise SystemExit(f"oldString not found in {path}")
            path.write_text(text.replace(old, new, \(replaceAll ? "-1" : "1")))
            PY
            """
        case "delete":
            guard let path = firstArgument(in: arguments, keys: pathPropertyAliases())?.value.stringValue else {
                return nil
            }
            return "rm -rf \(shellSingleQuoted(path))"
        case "grep":
            guard let pattern = firstArgument(in: arguments, keys: ["pattern", "query", "regex", "search", "searchPattern", "search_pattern"])?.value.stringValue else {
                return nil
            }
            let path = firstArgument(in: arguments, keys: pathPropertyAliases() + ["directory", "dir"])?.value.stringValue ?? "."
            var parts = ["rg", "--line-number", "--color", "never", "--hidden"]
            if let include = firstArgument(in: arguments, keys: ["glob", "include", "includeGlob", "include_glob", "fileGlob", "file_glob", "includePattern", "include_pattern"])?.value.stringValue,
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

    private static func listAsGlobArguments(_ arguments: [String: JSONValue], tool: OpenAIToolSpec, context: ToolCallContext? = nil) -> [String: JSONValue] {
        let properties = parameterPropertyNames(tool)
        guard !properties.isEmpty else { return arguments }
        var output: [String: JSONValue] = [:]
        if let patternKey = propertyName(matching: globPatternAliases(), in: properties) {
            output[patternKey] = normalizeToolArgumentValue(.string(arguments.isEmpty ? "**/*" : "*"), property: patternKey, tool: tool, context: context)
        }
        if let path = firstArgument(in: arguments, keys: globPathAliases())?.value,
           shouldIncludeOptionalPath(path),
           let pathKey = propertyName(matching: globPathAliases(), in: properties) {
            output[pathKey] = normalizeToolArgumentValue(path, property: pathKey, tool: tool, context: context)
        } else if let pathKey = propertyName(matching: globPathAliases(), in: properties),
                  isRequired(pathKey, in: requiredParameterNames(tool)) {
            output[pathKey] = normalizeToolArgumentValue(.string("."), property: pathKey, tool: tool, context: context)
        }
        return output.isEmpty ? arguments : output
    }

    private static func fillRequiredShellArguments(
        _ output: inout [String: JSONValue],
        source: [String: JSONValue],
        properties: [String],
        required: Set<String>,
        tool: OpenAIToolSpec
    ) {
        guard !required.isEmpty else { return }
        if let workdirKey = propertyName(matching: shellExplicitWorkdirAliases(), in: properties),
           isRequired(workdirKey, in: required),
           output[workdirKey] == nil {
            output[workdirKey] = firstArgument(in: source, keys: shellExplicitWorkdirAliases())?.value ?? .string(".")
        }
        if let timeoutKey = propertyName(matching: ["timeout", "timeoutMs", "timeout_ms", "timeoutSeconds", "timeout_seconds"], in: properties),
           isRequired(timeoutKey, in: required),
           output[timeoutKey] == nil {
            let timeoutArgument = firstArgument(in: source, keys: ["timeout", "timeoutMs", "timeout_ms", "timeoutSeconds", "timeout_seconds"])
            let timeout = timeoutArgument?.value ?? .number(120_000)
            output[timeoutKey] = normalizeToolArgumentValue(timeout, property: timeoutKey, tool: tool, context: nil, sourceProperty: timeoutArgument?.key)
        }
        if let descriptionKey = propertyName(matching: ["description"], in: properties),
           isRequired(descriptionKey, in: required),
           output[descriptionKey] == nil {
            let commandKey = propertyName(matching: shellCommandAliases(), in: properties)
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

    private static func normalizedGlobArguments(_ arguments: [String: JSONValue], context: ToolCallContext? = nil) -> GlobArguments {
        let patternKeys = globPatternAliases()
        let pathKeys = globPathAliases()
        var pattern = firstArgument(in: arguments, keys: patternKeys)
        var searchPath = firstArgument(in: arguments, keys: pathKeys)
        var consumed = Set<String>()

        if let key = pattern?.key { consumed.insert(key) }
        if let key = searchPath?.key { consumed.insert(key) }

        if let pathValue = searchPath?.value.stringValue {
            let absolutePath = absolutizeToolPath(pathValue, context: context)
            searchPath = NamedArgument(key: searchPath?.key ?? "path", value: .string(absolutePath))
            if looksLikeGlobPattern(absolutePath) {
                if let patternValue = pattern?.value.stringValue,
                   !looksLikeGlobPattern(patternValue),
                   looksLikeGlobSearchRoot(patternValue) {
                    searchPath = NamedArgument(key: searchPath?.key ?? "path", value: .string(absolutizeToolPath(patternValue, context: context)))
                    pattern = NamedArgument(key: pattern?.key ?? "pattern", value: .string(absolutePath))
                } else {
                    let split = splitGlobTargetPath(absolutePath)
                    searchPath = split.path.map { NamedArgument(key: searchPath?.key ?? "path", value: .string($0)) }
                    let combinedPattern = combineGlobPatterns(targetPattern: split.pattern, pattern: pattern?.value.stringValue)
                    pattern = combinedPattern.map { NamedArgument(key: pattern?.key ?? "pattern", value: .string($0)) }
                }
            }
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

    private static func looksLikePath(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("/")
            || trimmed.hasPrefix("./")
            || trimmed.hasPrefix("../")
            || trimmed.contains("/")
    }

    private static func looksLikeGlobSearchRoot(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if [".", "./", "..", "../"].contains(trimmed) {
            return true
        }
        if looksLikePath(trimmed) || trimmed.hasPrefix("~") || trimmed.hasPrefix("$") {
            return true
        }
        return !looksLikeGlobPattern(trimmed)
            && trimmed.range(of: #"\.[^/.]+$"#, options: .regularExpression) == nil
    }

    private static func shouldIncludeOptionalPath(_ value: JSONValue) -> Bool {
        guard let string = value.stringValue else { return true }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lower = trimmed.lowercased()
        return lower != "undefined" && lower != "null"
    }

    private static func normalizeToolArgumentValue(_ value: JSONValue, property: String, tool: OpenAIToolSpec, context: ToolCallContext?, sourceProperty: String? = nil) -> JSONValue {
        if value == .null, toolPropertyAllowsNull(tool: tool, property: property) {
            return value
        }
        if toolPropertyPrefersArray(tool: tool, property: property) {
            var values = arrayArgumentValue(value) ?? [value]
            let minimum = toolPropertyArrayMinimum(tool: tool, property: property)
            if values.count == 1, values.count < minimum {
                values = Array(repeating: values[0], count: minimum)
            }
            return .array(values.map { normalizeArrayItemArgumentValue($0, property: property, tool: tool, context: context) })
        }
        if case .number(let number) = value,
           toolPropertyPrefersSecondsTimeout(tool: tool, property: property) {
            return .number(normalizeTimeoutForSecondsTool(number, sourceProperty: sourceProperty))
        }
        guard let string = value.stringValue,
              toolPropertyPrefersAbsolutePath(tool: tool, property: property) else {
            return value
        }
        return .string(absolutizeToolPath(string, context: context))
    }

    private static func normalizeArrayItemArgumentValue(_ value: JSONValue, property: String, tool: OpenAIToolSpec, context: ToolCallContext?) -> JSONValue {
        guard let string = value.stringValue,
              toolPropertyPrefersAbsolutePath(tool: tool, property: property) else {
            return value
        }
        return .string(absolutizeToolPath(string, context: context))
    }

    private static func toolPropertyPrefersArray(tool: OpenAIToolSpec, property: String) -> Bool {
        guard case .object(let schema)? = parameterPropertySchema(property, tool: tool) else {
            return false
        }
        if directSchemaLooksArray(schema) {
            return true
        }
        let types = schemaJSONTypes(schema).filter { $0 != "null" }
        return !types.isEmpty && types.allSatisfy { $0 == "array" }
    }

    private static func toolPropertyAllowsNull(tool: OpenAIToolSpec, property: String) -> Bool {
        guard case .object(let schema)? = parameterPropertySchema(property, tool: tool) else {
            return false
        }
        return schemaAllowsJSONType(schema, type: "null")
    }

    private static func toolPropertyArrayMinimum(tool: OpenAIToolSpec, property: String) -> Int {
        guard case .object(let schema)? = parameterPropertySchema(property, tool: tool) else {
            return 0
        }
        let arraySchema = preferredArraySchema(schema) ?? schema
        return max(0, arraySchema["minItems"]?.integerValue ?? 0)
    }

    private static func normalizeTimeoutForSecondsTool(_ value: Double, sourceProperty: String?) -> Double {
        let source = normalizedName(sourceProperty ?? "")
        if ["timeoutseconds", "seconds"].contains(source) {
            return value
        }
        if ["timeoutms", "timeoutmilliseconds", "milliseconds"].contains(source) {
            return max(1, ceil(value / 1000))
        }
        return value >= 1000 ? max(1, ceil(value / 1000)) : value
    }

    private static func toolPropertyPrefersSecondsTimeout(tool: OpenAIToolSpec, property: String) -> Bool {
        let normalizedProperty = normalizedName(property)
        guard ["timeout", "timeoutseconds", "seconds"].contains(normalizedProperty) else {
            return false
        }
        if ["timeoutseconds", "seconds"].contains(normalizedProperty) {
            return true
        }
        guard case .object(let schema)? = parameterPropertySchema(property, tool: tool),
              let description = schema["description"]?.stringValue?.lowercased() else {
            return false
        }
        return description.range(of: #"\bseconds?\b"#, options: .regularExpression) != nil
            && description.range(of: #"\b(milliseconds?|ms)\b"#, options: .regularExpression) == nil
    }

    private static func toolPropertyPrefersAbsolutePath(tool: OpenAIToolSpec, property: String) -> Bool {
        if case .object(let schema)? = parameterPropertySchema(property, tool: tool),
           let description = schema["description"]?.stringValue?.lowercased(),
           description.contains("absolute path") {
            return true
        }
        let normalizedProperty = normalizedName(property)
        return ["read", "write", "edit", "delete"].contains(canonicalToolName(tool.name))
            && ["filepath", "absolutepath"].contains(normalizedProperty)
    }

    private static func absolutizeToolPath(_ value: String, context: ToolCallContext?) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if trimmed.hasPrefix("$") || trimmed.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) != nil {
            return trimmed
        }
        if trimmed == "~" || trimmed.hasPrefix("~/") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return normalizePosixPath(trimmed == "~" ? home : "\(home)/\(trimmed.dropFirst(2))")
        }
        if trimmed.hasPrefix("/") {
            return normalizePosixPath(trimmed)
        }
        guard let base = sanitizeContextPath(context?.workingDirectory), base.hasPrefix("/") else {
            return trimmed
        }
        let baseWithoutTrailingSlash = base.replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
        let prefix = baseWithoutTrailingSlash.isEmpty ? "/" : baseWithoutTrailingSlash
        return normalizePosixPath("\(prefix)/\(trimmed)")
    }

    private static func normalizePosixPath(_ value: String) -> String {
        guard value.hasPrefix("/") else {
            return value.replacingOccurrences(of: #"/{2,}"#, with: "/", options: .regularExpression)
        }
        var parts: [String] = []
        for part in value.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
            if part == "." {
                continue
            }
            if part == ".." {
                _ = parts.popLast()
                continue
            }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }

    private static func splitGlobTargetPath(_ value: String) -> (path: String?, pattern: String?) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstGlob = trimmed.firstIndex(where: { "*?[]{}".contains($0) }) else {
            return (trimmed, nil)
        }
        let beforeGlob = trimmed[..<firstGlob]
        let slash = beforeGlob.lastIndex(of: "/")
        let base: String
        let pattern: String
        if let slash {
            base = slash == trimmed.startIndex ? "/" : String(trimmed[..<slash])
            pattern = String(trimmed[trimmed.index(after: slash)...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else {
            base = ""
            pattern = String(trimmed)
        }
        return (base.isEmpty ? nil : base, pattern.isEmpty ? nil : pattern)
    }

    private static func combineGlobPatterns(targetPattern: String?, pattern: String?) -> String? {
        let cleanTarget = targetPattern?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let cleanPattern = pattern?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let cleanTarget, !cleanTarget.isEmpty else { return cleanPattern }
        guard let cleanPattern, !cleanPattern.isEmpty else { return cleanTarget }
        if cleanTarget == "**" {
            return cleanPattern == "*" ? "**/*" : "**/\(cleanPattern)"
        }
        if cleanTarget == "*" {
            return cleanPattern
        }
        if cleanPattern == "*" {
            return cleanTarget
        }
        return cleanPattern
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
        properties: [String],
        context: ToolCallContext? = nil
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
            pathKey: normalizeToolArgumentValue(path, property: pathKey, tool: tool, context: context)
        ]

        switch canonical {
        case "write":
            guard let content = firstArgument(in: arguments, keys: fileContentAliases())?.value,
                  let contentKey = propertyName(matching: fileContentAliases(), in: properties) else {
                return nil
            }
            output[contentKey] = content
        case "edit":
            guard let oldText = firstArgument(in: arguments, keys: oldTextAliases())?.value,
                  let newText = firstArgument(in: arguments, keys: newTextAliases())?.value,
                  let oldKey = propertyName(matching: oldTextAliases(), in: properties),
                  let newKey = propertyName(matching: newTextAliases(), in: properties) else {
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
            return propertyName(matching: fileContentAliases(), in: properties) != nil
        case "edit":
            return propertyName(matching: oldTextAliases(), in: properties) != nil
                && propertyName(matching: newTextAliases(), in: properties) != nil
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
              case .object(let schema) = propertySchema else {
            return []
        }
        return unionStringEnumValues(schema["enum"], schema["const"])
    }

    private static func parameterPropertySchema(_ property: String, tool: OpenAIToolSpec) -> JSONValue? {
        let shape = parameterSchemaShape(tool.parameters)
        if let exact = shape.properties[property] {
            return exact
        }
        let normalized = normalizedName(property)
        return shape.properties.first(where: { normalizedName($0.key) == normalized })?.value
    }

    private static func toolArgumentsSatisfySchema(_ arguments: [String: JSONValue], tool: OpenAIToolSpec) -> Bool {
        let shape = parameterSchemaShape(tool.parameters)
        guard !shape.propertyOrder.isEmpty else { return true }
        for required in shape.required {
            guard let property = propertyName(matching: [required], in: shape.propertyOrder),
                  argumentValueSatisfiesSchema(arguments[property], schema: shape.properties[property], required: true) else {
                return false
            }
        }
        for (property, value) in arguments {
            guard let propertyName = propertyName(matching: [property], in: shape.propertyOrder),
                  let schema = shape.properties[propertyName] else {
                continue
            }
            if !argumentValueSatisfiesSchema(value, schema: schema, required: false) {
                return false
            }
        }
        return true
    }

    private static func argumentValueSatisfiesSchema(_ value: JSONValue?, schema: JSONValue?, required: Bool) -> Bool {
        guard let value else { return !required }
        let canonicalSchema = schemaWithInheritedDefinitions(schema, root: schema)
        guard let object = canonicalParameterSchemaObject(canonicalSchema, root: canonicalSchema, depth: 0, seenRefs: []) else {
            return value != .null || !required
        }
        if value == .null {
            return schemaAllowsJSONType(object, type: "null")
        }
        if let const = object["const"], value != const {
            return false
        }
        if case .array(let values)? = object["enum"], !values.contains(value) {
            return false
        }
        let anyOf = composedParameterSchemas(object["anyOf"])
        if !anyOf.isEmpty, !anyOf.contains(where: { argumentValueSatisfiesSchema(value, schema: schemaWithInheritedDefinitions($0, root: .object(object)), required: true) }) {
            return false
        }
        let oneOf = composedParameterSchemas(object["oneOf"])
        if !oneOf.isEmpty, !oneOf.contains(where: { argumentValueSatisfiesSchema(value, schema: schemaWithInheritedDefinitions($0, root: .object(object)), required: true) }) {
            return false
        }
        let allOf = composedParameterSchemas(object["allOf"])
        if !allOf.isEmpty, !allOf.allSatisfy({ argumentValueSatisfiesSchema(value, schema: schemaWithInheritedDefinitions($0, root: .object(object)), required: true) }) {
            return false
        }
        let types = schemaJSONTypes(object)
        if !types.isEmpty, !types.contains(where: { jsonValue(value, matchesType: $0) }) {
            return false
        }
        if objectConstraintsApply(object, value: value, types: types),
           !objectValueSatisfiesSchema(value, schema: object) {
            return false
        }
        if arrayConstraintsApply(object, value: value, types: types),
           !arrayValueSatisfiesSchema(value, schema: object) {
            return false
        }
        return true
    }

    private static func objectConstraintsApply(_ schema: [String: JSONValue], value: JSONValue, types: [String]) -> Bool {
        guard schema["properties"] != nil || schema["required"] != nil || schema["additionalProperties"] != nil else {
            return false
        }
        if jsonValue(value, matchesType: "object") {
            return true
        }
        return types.isEmpty || types.contains("object")
    }

    private static func objectValueSatisfiesSchema(_ value: JSONValue, schema: [String: JSONValue]) -> Bool {
        guard case .object(let values) = value else { return false }
        let properties: [String: JSONValue]
        if case .object(let object)? = schema["properties"] {
            properties = object
        } else {
            properties = [:]
        }
        let propertyOrder = Array(properties.keys)
        let required: [String]
        if case .array(let values)? = schema["required"] {
            required = values.compactMap(\.stringValue)
        } else {
            required = []
        }
        for requiredProperty in required {
            let property = propertyName(matching: [requiredProperty], in: propertyOrder) ?? requiredProperty
            let propertySchema = schemaWithInheritedDefinitions(properties[property], root: .object(schema))
            guard argumentValueSatisfiesSchema(values[property], schema: propertySchema, required: true) else {
                return false
            }
        }
        for (property, nestedValue) in values {
            if let propertyName = propertyName(matching: [property], in: propertyOrder),
               let propertySchema = properties[propertyName] {
                let nestedSchema = schemaWithInheritedDefinitions(propertySchema, root: .object(schema))
                if !argumentValueSatisfiesSchema(nestedValue, schema: nestedSchema, required: false) {
                    return false
                }
                continue
            }
            if schema["additionalProperties"] == .bool(false) {
                return false
            }
            if case .object? = schema["additionalProperties"],
               !argumentValueSatisfiesSchema(nestedValue, schema: schema["additionalProperties"], required: false) {
                return false
            }
        }
        return true
    }

    private static func arrayConstraintsApply(_ schema: [String: JSONValue], value: JSONValue, types: [String]) -> Bool {
        guard schema["items"] != nil || schema["prefixItems"] != nil || schema["minItems"] != nil || schema["maxItems"] != nil else {
            return false
        }
        if jsonValue(value, matchesType: "array") {
            return true
        }
        return types.isEmpty || types.contains("array")
    }

    private static func arrayValueSatisfiesSchema(_ value: JSONValue, schema: [String: JSONValue]) -> Bool {
        guard case .array(let values) = value else { return false }
        if let minItems = schema["minItems"]?.integerValue, values.count < minItems {
            return false
        }
        if let maxItems = schema["maxItems"]?.integerValue, values.count > maxItems {
            return false
        }
        let prefixItems: [JSONValue]
        if case .array(let values)? = schema["prefixItems"] {
            prefixItems = values
        } else {
            prefixItems = []
        }
        for index in 0..<min(prefixItems.count, values.count) {
            let itemSchema = schemaWithInheritedDefinitions(prefixItems[index], root: .object(schema))
            if !argumentValueSatisfiesSchema(values[index], schema: itemSchema, required: true) {
                return false
            }
        }
        if schema["items"] == .bool(false), values.count > prefixItems.count {
            return false
        }
        if case .object? = schema["items"] {
            let itemSchema = schemaWithInheritedDefinitions(schema["items"], root: .object(schema))
            for index in prefixItems.count..<values.count {
                if !argumentValueSatisfiesSchema(values[index], schema: itemSchema, required: true) {
                    return false
                }
            }
        }
        return true
    }

    private static func schemaJSONTypes(_ schema: [String: JSONValue]) -> [String] {
        if let value = schema["type"]?.stringValue {
            return [value]
        }
        if case .array(let values)? = schema["type"] {
            return values.compactMap(\.stringValue)
        }
        let composed = composedSchemaObjects(schema)
        if !composed.isEmpty {
            return composed.reduce(into: []) { output, object in
                for type in schemaJSONTypes(object) where !output.contains(type) {
                    output.append(type)
                }
            }
        }
        return []
    }

    private static func schemaAllowsJSONType(_ schema: [String: JSONValue], type: String) -> Bool {
        if type == "null", schema["nullable"] == .bool(true) {
            return true
        }
        let types = schemaJSONTypes(schema)
        return types.isEmpty || types.contains(type)
    }

    private static func preferredArraySchema(_ schema: [String: JSONValue]) -> [String: JSONValue]? {
        if directSchemaLooksArray(schema) {
            return schema
        }
        let arraySchemas = composedSchemaObjects(schema).filter { object in
            let types = schemaJSONTypes(object).filter { $0 != "null" }
            return directSchemaLooksArray(object)
                || (!types.isEmpty && types.allSatisfy { $0 == "array" })
        }
        return arraySchemas.first
    }

    private static func directSchemaLooksArray(_ schema: [String: JSONValue]) -> Bool {
        if schema["items"] != nil || schema["prefixItems"] != nil {
            return true
        }
        let directTypes: [String]
        if let value = schema["type"]?.stringValue {
            directTypes = [value]
        } else if case .array(let values)? = schema["type"] {
            directTypes = values.compactMap(\.stringValue)
        } else {
            directTypes = []
        }
        let nonNull = directTypes.filter { $0 != "null" }
        return !nonNull.isEmpty && nonNull.allSatisfy { $0 == "array" }
    }

    private static func composedSchemaObjects(_ schema: [String: JSONValue]) -> [[String: JSONValue]] {
        (composedParameterSchemas(schema["anyOf"]) + composedParameterSchemas(schema["oneOf"]) + composedParameterSchemas(schema["allOf"])).compactMap { value in
            guard case .object(let object) = value else { return nil }
            return object
        }
    }

    private static func jsonValue(_ value: JSONValue, matchesType type: String) -> Bool {
        switch type {
        case "string":
            return value.stringValue != nil
        case "number":
            if case .number = value { return true }
            return false
        case "integer":
            if case .number(let number) = value { return number.rounded() == number }
            return false
        case "boolean":
            if case .bool = value { return true }
            return false
        case "array":
            if case .array = value { return true }
            return false
        case "object":
            if case .object = value { return true }
            return false
        case "null":
            return value == .null
        default:
            return true
        }
    }

    private static func toolRequiredArgumentSummary(_ tool: OpenAIToolSpec) -> String {
        let shape = parameterSchemaShape(tool.parameters)
        guard !shape.required.isEmpty else { return "none" }
        return shape.required.sorted().flatMap { property in
            let canonicalProperty = shape.propertyOrder.first { normalizedName($0) == normalizedName(property) } ?? property
            return requiredArgumentSummary(prefix: canonicalProperty, schema: shape.properties[canonicalProperty])
        }.joined(separator: ", ")
    }

    private static func requiredArgumentSummary(prefix: String, schema: JSONValue?) -> [String] {
        guard case .object(let object)? = schema else {
            return ["\(prefix):unknown"]
        }
        let nestedProperties: [String: JSONValue]
        if case .object(let properties)? = object["properties"] {
            nestedProperties = properties
        } else {
            nestedProperties = [:]
        }
        let nestedRequired: [String]
        if case .array(let values)? = object["required"] {
            nestedRequired = values.compactMap(\.stringValue)
        } else {
            nestedRequired = []
        }
        if !nestedProperties.isEmpty, !nestedRequired.isEmpty {
            let propertyOrder = Array(nestedProperties.keys)
            return nestedRequired.sorted().flatMap { property in
                let canonicalProperty = propertyName(matching: [property], in: propertyOrder) ?? property
                return requiredArgumentSummary(prefix: "\(prefix).\(canonicalProperty)", schema: nestedProperties[canonicalProperty])
            }
        }
        if case .object? = object["items"] {
            let itemSummaries = requiredArgumentSummary(prefix: "\(prefix)[]", schema: object["items"])
            if itemSummaries.contains(where: { $0 != "\(prefix)[]:unknown" }) {
                return itemSummaries
            }
        }
        return ["\(prefix):\(schemaTypeLabel(schema))"]
    }

    private static func toolSchemaPropertySummary(_ tool: OpenAIToolSpec) -> String {
        let shape = parameterSchemaShape(tool.parameters)
        guard !shape.propertyOrder.isEmpty else { return "none" }
        return shape.propertyOrder.map { property in
            "\(property):\(schemaTypeLabel(shape.properties[property]))"
        }.joined(separator: ", ")
    }

    private static func schemaTypeLabel(_ schema: JSONValue?) -> String {
        guard case .object(let object)? = schema else { return "unknown" }
        let enumValues: [String]
        if case .array(let values)? = object["enum"] {
            enumValues = values.compactMap(\.stringValue)
        } else {
            enumValues = []
        }
        if !enumValues.isEmpty {
            return "enum(\(enumValues.joined(separator: "|")))"
        }
        let suffix = object["const"]?.stringValue.map { "=\($0)" } ?? ""
        let types = schemaJSONTypes(object)
        return "\(types.isEmpty ? "any" : types.joined(separator: "|"))\(suffix)"
    }

    private static func safeJSONForPrompt(_ value: Any) -> String {
        let json = jsonString(value)
        guard json.count > 700 else { return json }
        return "\(json.prefix(700))..."
    }

    private struct ParameterSchemaShape {
        var properties: [String: JSONValue]
        var propertyOrder: [String]
        var required: Set<String>
        var allowsAdditionalProperties: Bool
    }

    private static func parameterSchemaShape(
        _ value: JSONValue?,
        depth: Int = 0,
        root: JSONValue? = nil,
        seenRefs: Set<String> = []
    ) -> ParameterSchemaShape {
        let schemaRoot = root ?? value
        guard depth <= 5,
              let object = canonicalParameterSchemaObject(value, root: schemaRoot, depth: depth, seenRefs: seenRefs) else {
            return emptyParameterSchemaShape()
        }

        let direct = directParameterSchemaShape(object, root: schemaRoot, depth: depth, seenRefs: seenRefs)
        let allOf = composedParameterSchemas(object["allOf"]).map {
            parameterSchemaShape($0, depth: depth + 1, root: schemaRoot, seenRefs: seenRefs)
        }
        let variants = (composedParameterSchemas(object["anyOf"]) + composedParameterSchemas(object["oneOf"]))
            .map { parameterSchemaShape($0, depth: depth + 1, root: schemaRoot, seenRefs: seenRefs) }

        return mergeParameterSchemaShapes(
            [
                direct,
                mergeParameterSchemaShapes(allOf, requiredMode: .union),
                mergeParameterSchemaShapes(variants, requiredMode: .intersection)
            ],
            requiredMode: .union
        )
    }

    private static func emptyParameterSchemaShape() -> ParameterSchemaShape {
        ParameterSchemaShape(properties: [:], propertyOrder: [], required: [], allowsAdditionalProperties: false)
    }

    private static func canonicalParameterSchemaObject(
        _ value: JSONValue?,
        root: JSONValue?,
        depth: Int,
        seenRefs: Set<String>
    ) -> [String: JSONValue]? {
        guard depth <= 5,
              let dereferenced = dereferencedParameterSchemaValue(value, root: root, depth: depth, seenRefs: seenRefs),
              case .object(let object) = dereferenced else {
            return nil
        }
        if object["properties"] == nil {
            for key in parameterSchemaWrapperKeys() {
                if case .object? = object[key] {
                    return canonicalParameterSchemaObject(object[key], root: root, depth: depth + 1, seenRefs: seenRefs)
                }
            }
        }
        return object
    }

    private static func parameterSchemaWrapperKeys() -> [String] {
        ["schema", "json_schema", "input_schema", "inputSchema"]
    }

    private static func schemaWithInheritedDefinitions(_ schema: JSONValue?, root: JSONValue?) -> JSONValue? {
        guard case .object(var object)? = schema else { return schema }
        for (key, value) in schemaDefinitionValues(root: root) where object[key] == nil {
            object[key] = value
        }
        return .object(object)
    }

    private static func schemaDefinitionValues(root: JSONValue?) -> [(String, JSONValue)] {
        guard case .object(let object)? = root else { return [] }
        var values: [(String, JSONValue)] = []
        for key in ["$defs", "definitions"] {
            if let value = object[key] {
                values.append((key, value))
            }
        }
        for key in parameterSchemaWrapperKeys() {
            values.append(contentsOf: schemaDefinitionValues(root: object[key]))
        }
        return values
    }

    private static func directParameterSchemaShape(
        _ root: [String: JSONValue],
        root schemaRoot: JSONValue?,
        depth: Int,
        seenRefs: Set<String>
    ) -> ParameterSchemaShape {
        let properties: [String: JSONValue]
        if case .object(let object)? = root["properties"] {
            properties = object.mapValues {
                let schema = dereferencedParameterSchemaValue($0, root: schemaRoot, depth: depth + 1, seenRefs: seenRefs) ?? $0
                return schemaWithInheritedDefinitions(schema, root: schemaRoot) ?? schema
            }
        } else {
            properties = [:]
        }
        let required: Set<String>
        if case .array(let values)? = root["required"] {
            required = Set(values.compactMap(\.stringValue).map(normalizedName))
        } else {
            required = []
        }
        let allowsAdditionalProperties: Bool
        if case .bool(true)? = root["additionalProperties"] {
            allowsAdditionalProperties = true
        } else if case .object? = root["additionalProperties"] {
            allowsAdditionalProperties = true
        } else {
            allowsAdditionalProperties = false
        }
        return ParameterSchemaShape(
            properties: properties,
            propertyOrder: Array(properties.keys),
            required: required,
            allowsAdditionalProperties: allowsAdditionalProperties
        )
    }

    private static func composedParameterSchemas(_ value: JSONValue?) -> [JSONValue] {
        guard case .array(let values)? = value else { return [] }
        return values
    }

    private static func dereferencedParameterSchemaValue(
        _ value: JSONValue?,
        root: JSONValue?,
        depth: Int,
        seenRefs: Set<String>
    ) -> JSONValue? {
        guard depth <= 5,
              case .object(let object)? = value,
              let reference = object["$ref"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reference.isEmpty,
              !seenRefs.contains(reference),
              let target = localSchemaReference(root: root, reference: reference) else {
            return value
        }
        var nextSeenRefs = seenRefs
        nextSeenRefs.insert(reference)
        return dereferencedParameterSchemaValue(target, root: root, depth: depth + 1, seenRefs: nextSeenRefs) ?? target
    }

    private static func localSchemaReference(root: JSONValue?, reference: String) -> JSONValue? {
        guard reference.hasPrefix("#") else { return nil }
        if let direct = jsonPointerTarget(root: root, reference: reference) {
            return direct
        }
        guard case .object(let object)? = root else { return nil }
        for key in parameterSchemaWrapperKeys() {
            if let target = jsonPointerTarget(root: object[key], reference: reference) {
                return target
            }
        }
        return nil
    }

    private static func jsonPointerTarget(root: JSONValue?, reference: String) -> JSONValue? {
        guard reference.hasPrefix("#") else { return nil }
        if reference == "#" {
            return root
        }
        guard reference.hasPrefix("#/") else { return nil }
        var current = root
        for token in reference.dropFirst(2).split(separator: "/", omittingEmptySubsequences: false).map({ jsonPointerToken(String($0)) }) {
            guard let value = current else { return nil }
            switch value {
            case .object(let object):
                current = object[token]
            case .array(let array):
                guard let index = Int(token), array.indices.contains(index) else { return nil }
                current = array[index]
            default:
                return nil
            }
        }
        return current
    }

    private static func jsonPointerToken(_ value: String) -> String {
        value
            .replacingOccurrences(of: "~1", with: "/")
            .replacingOccurrences(of: "~0", with: "~")
    }

    private enum RequiredMergeMode {
        case union
        case intersection
    }

    private static func mergeParameterSchemaShapes(_ shapes: [ParameterSchemaShape], requiredMode: RequiredMergeMode) -> ParameterSchemaShape {
        let useful = shapes.filter { !$0.propertyOrder.isEmpty || !$0.required.isEmpty || $0.allowsAdditionalProperties }
        guard !useful.isEmpty else { return emptyParameterSchemaShape() }
        var properties: [String: JSONValue] = [:]
        var propertyOrder: [String] = []
        for shape in useful {
            for property in shape.propertyOrder {
                if !propertyOrder.contains(property) {
                    propertyOrder.append(property)
                }
                if let existing = properties[property], let next = shape.properties[property] {
                    properties[property] = mergedPropertySchema(existing, next)
                } else if properties[property] == nil {
                    properties[property] = shape.properties[property]
                }
            }
        }

        let required: Set<String>
        switch requiredMode {
        case .union:
            required = useful.reduce(into: Set<String>()) { output, shape in output.formUnion(shape.required) }
        case .intersection:
            let nonEmpty = useful.map(\.required).filter { !$0.isEmpty }
            required = nonEmpty.dropFirst().reduce(nonEmpty.first ?? []) { current, next in current.intersection(next) }
        }

        return ParameterSchemaShape(
            properties: properties,
            propertyOrder: propertyOrder,
            required: required,
            allowsAdditionalProperties: useful.contains(where: \.allowsAdditionalProperties)
        )
    }

    private static func mergedPropertySchema(_ left: JSONValue, _ right: JSONValue) -> JSONValue {
        guard case .object(let leftObject) = left,
              case .object(let rightObject) = right else {
            return left
        }
        var merged = rightObject.merging(leftObject) { _, left in left }
        let enumValues = unionStringEnumValues(leftObject["enum"], rightObject["enum"], leftObject["const"], rightObject["const"])
        if !enumValues.isEmpty {
            merged["enum"] = .array(enumValues.map(JSONValue.string))
            if enumValues.count > 1 {
                merged["const"] = nil
            }
        }
        if merged["description"] == nil, let description = rightObject["description"] {
            merged["description"] = description
        }
        return .object(merged)
    }

    private static func unionStringEnumValues(_ values: JSONValue?...) -> [String] {
        var output: [String] = []
        for value in values {
            let items: [JSONValue]
            switch value {
            case .array(let values):
                items = values
            case .some(let value):
                items = [value]
            case .none:
                items = []
            }
            for item in items {
                guard let string = item.stringValue, !output.contains(string) else { continue }
                output.append(string)
            }
        }
        return output
    }

    private struct WrapperObjectArgumentProperty {
        var key: String
        var schema: JSONValue
    }

    private static func wrapperObjectArgumentProperty(tool: OpenAIToolSpec, properties: [String]) -> WrapperObjectArgumentProperty? {
        guard !properties.isEmpty else { return nil }
        for candidate in wrapperObjectPropertyAliases() {
            guard let key = propertyName(matching: [candidate], in: properties),
                  let schema = parameterPropertySchema(key, tool: tool) else {
                continue
            }
            let nestedTool = OpenAIToolSpec(name: tool.name, description: tool.description, parameters: schema)
            if !parameterPropertyNames(nestedTool).isEmpty {
                return WrapperObjectArgumentProperty(key: key, schema: schema)
            }
        }
        return nil
    }

    private static func wrapperObjectPropertyAliases() -> [String] {
        ["input", "args", "arguments", "params", "parameters", "payload", "data"]
    }

    private static func patchStyleFileArguments(
        _ arguments: [String: JSONValue],
        sdkToolName: String,
        tool: OpenAIToolSpec,
        properties: [String],
        context: ToolCallContext? = nil
    ) -> [String: JSONValue]? {
        let canonical = canonicalToolName(sdkToolName)
        guard ["write", "edit", "delete"].contains(canonical),
              let patchKey = patchPropertyKey(tool: tool, properties: properties) else {
            return nil
        }
        let path = firstArgument(in: arguments, keys: pathPropertyAliases() + ["target_file", "targetFile"])?.value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty

        let patch: String
        switch canonical {
        case "write":
            guard let path,
                  let content = firstArgument(in: arguments, keys: fileContentAliases())?.value.stringValue else {
                return nil
            }
            patch = addFilePatch(path: path, content: content)
        case "edit":
            if let patchContent = firstArgument(in: arguments, keys: ["patchContent", "patch_content", "patch", "diff", "unifiedDiff", "unified_diff"])?.value.stringValue {
                patch = patchContent
            } else {
                guard let path,
                      let oldText = firstArgument(in: arguments, keys: oldTextAliases())?.value.stringValue,
                      let newText = firstArgument(in: arguments, keys: newTextAliases())?.value.stringValue else {
                    return nil
                }
                patch = updateFilePatch(path: path, oldText: oldText, newText: newText)
            }
        default:
            guard let path else { return nil }
            patch = deleteFilePatch(path: path)
        }

        var output: [String: JSONValue] = [patchKey: .string(patch)]
        if let pathKey = propertyName(matching: pathPropertyAliases(), in: properties) {
            if let path {
                output[pathKey] = normalizeToolArgumentValue(.string(path), property: pathKey, tool: tool, context: context)
            } else if isRequired(pathKey, in: requiredParameterNames(tool)) {
                return nil
            }
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
        if let wrapper = wrapperObjectArgumentProperty(tool: tool, properties: properties) {
            if canonical == "mcp",
               has(["toolName", "tool_name", "tool", "name"]) || normalizedName(tool.name).contains("mcp") {
                return true
            }
            let nestedTool = OpenAIToolSpec(name: tool.name, description: tool.description, parameters: wrapper.schema)
            return schemaLooksCompatible(sdkToolName: sdkToolName, tool: nestedTool)
        }
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
        let toolCanonical = canonicalToolName(tool.name)
        switch canonical {
        case "shell":
            return has(shellCommandAliases())
        case "write":
            return has(pathPropertyAliases()) && has(fileContentAliases())
        case "read":
            return has(pathPropertyAliases())
        case "delete":
            return toolCanonical == "delete" && has(pathPropertyAliases())
        case "edit":
            return has(pathPropertyAliases())
                && has(oldTextAliases())
                && has(newTextAliases())
        case "grep":
            return has(["pattern", "query", "regex"])
        case "glob":
            return has(globPatternAliases(includeQuery: false)) || (canonicalToolName(tool.name) == "glob" && has(["query"]))
        case "ls":
            return has(pathPropertyAliases() + ["directory", "dir"])
        case "readlints":
            return has(["paths", "files", "filePaths", "file_paths"])
        case "mcp":
            return has(["toolName", "tool_name", "tool", "name"])
        case "semsearch":
            return toolCanonical == "semsearch" && has(["query", "pattern", "search"])
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
        case "write", "read", "edit", "delete", "grep", "glob", "ls", "semsearch":
            return true
        default:
            return false
        }
    }

    private static func parameterPropertyNames(_ tool: OpenAIToolSpec) -> [String] {
        parameterSchemaShape(tool.parameters).propertyOrder
    }

    private static func requiredParameterNames(_ tool: OpenAIToolSpec) -> Set<String> {
        parameterSchemaShape(tool.parameters).required
    }

    private static func isRequired(_ property: String, in required: Set<String>) -> Bool {
        required.contains(normalizedName(property))
    }

    private static func parameterAllowsAdditionalProperties(_ tool: OpenAIToolSpec) -> Bool {
        parameterSchemaShape(tool.parameters).allowsAdditionalProperties
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
        case "absolutepath", "relativepath", "filepath", "filename", "target", "targetpath", "targetfile", "file":
            return pathPropertyAliases()
        case "commandline", "shellcommand", "cmd", "command", "script", "code":
            return shellCommandAliases()
        case "contents", "content", "filetext", "body", "data", "value":
            return fileContentAliases() + ["newString"]
        case "newcontents", "newtext", "newstring", "replacement", "replace", "replacewith":
            return newTextAliases() + fileContentAliases()
        case "oldcontents", "oldstring", "oldtext", "searchstring", "find", "findtext":
            return oldTextAliases() + ["text"]
        case "glob", "globs", "globpattern", "globpatterns", "fileglob", "fileglobs", "filepattern", "filepatterns", "includepattern", "includepatterns", "include", "includes":
            return globPatternAliases()
        case "literal", "fixedstring":
            return ["literal", "fixedString", "fixed_string"]
        case "pattern", "query", "regex", "search":
            return ["pattern", "query", "regex", "search", "prompt"]
        case "targetdirectory", "targetdirectories", "targeting", "searchpath", "searchpaths", "basepath", "basepaths", "root", "roots", "rootdir", "rootdirs", "directory", "directories", "folder", "folders", "dir", "cwd", "workingdirectory", "workdir":
            return globPathAliases() + pathPropertyAliases() + ["pattern"]
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
            if ["globpattern", "globpatterns", "fileglob", "fileglobs", "filepattern", "filepatterns", "includepattern", "includepatterns", "glob", "globs", "include", "includes", "pattern", "patterns", "query"].contains(normalizedKey) {
                return globPatternAliases()
            }
            if ["targeting", "targetdirectory", "targetdirectories", "searchpath", "searchpaths", "basepath", "basepaths", "root", "roots", "rootdir", "rootdirs", "cwd", "directory", "directories", "folder", "folders", "dir", "path", "paths"].contains(normalizedKey) {
                return globPathAliases()
            }
        case "grep":
            if ["query", "search", "searchstring", "regex", "pattern"].contains(normalizedKey) {
                return ["pattern", "query", "regex", "search"]
            }
            if ["globpattern", "glob", "include"].contains(normalizedKey) {
                return ["include", "glob", "files"]
            }
            if ["literal", "fixedstring"].contains(normalizedKey) {
                return ["literal", "fixedString", "fixed_string"]
            }
        case "read", "delete":
            if ["targeting", "target", "targetpath", "targetfile", "filepath", "absolutepath", "relativepath", "path", "file"].contains(normalizedKey) {
                return pathPropertyAliases()
            }
        case "write":
            if ["targeting", "target", "targetpath", "targetfile", "filepath", "absolutepath", "relativepath", "path", "file"].contains(normalizedKey) {
                return pathPropertyAliases()
            }
            if ["newcontents", "contents", "content", "text", "body", "data", "value", "filetext"].contains(normalizedKey) {
                return fileContentAliases()
            }
        case "edit":
            if ["targeting", "target", "targetpath", "targetfile", "filepath", "absolutepath", "relativepath", "path", "file"].contains(normalizedKey) {
                return pathPropertyAliases()
            }
            if ["oldstring", "oldtext", "oldcontents", "search", "searchstring", "find", "findtext"].contains(normalizedKey) {
                return oldTextAliases()
            }
            if ["newstring", "newtext", "newcontents", "replacement", "replace", "replacewith", "content"].contains(normalizedKey) {
                return newTextAliases()
            }
        case "shell":
            if ["cmd", "commandline", "command", "script", "shellcommand", "code"].contains(normalizedKey) {
                return shellCommandAliases()
            }
            if ["workingdirectory", "cwd", "directory", "dir", "path", "workdir"].contains(normalizedKey) {
                return shellWorkdirAliases()
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
        case "bash", "runshellcommand", "runterminalcommand", "runterminalcmd", "terminal", "execute", "executecommand", "runcommand", "run":
            return "shell"
        case "writefile", "createfile", "strreplaceeditor":
            return "write"
        case "editfile", "replacefile", "searchreplace":
            return "edit"
        case "readfile", "openfile", "viewfile":
            return "read"
        case "deletefile", "removefile":
            return "delete"
        case "search", "searchfiles", "searchfilesystem", "ripgrep", "rg":
            return "grep"
        case "globfiles", "fileglob", "filesearch", "find", "findfile", "findfiles":
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
            return ["shell", "bash", "run_shell_command", "run_terminal_command", "run_terminal_cmd", "terminal", "execute", "execute_command", "run_command", "run"]
        case "write":
            return ["write", "write_file", "create_file", "str_replace_editor"]
        case "edit":
            return ["edit", "edit_file", "replace_file", "search_replace"]
        case "read":
            return ["read", "read_file", "open_file", "view_file"]
        case "delete":
            return ["delete", "delete_file", "remove_file"]
        case "grep":
            return ["grep", "search", "search_files", "search_filesystem", "ripgrep", "rg"]
        case "glob":
            return ["glob", "glob_files", "file_glob", "file_search", "find", "find_file", "find_files"]
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
        [
            "path", "file_path", "filePath", "filename", "file",
            "target", "targetPath", "target_path", "targetFile", "target_file",
            "absolutePath", "absolute_path", "relativePath", "relative_path"
        ]
    }

    private static func fileContentAliases() -> [String] {
        [
            "fileText", "file_text", "content", "contents", "text", "body", "data", "value",
            "newContents", "new_contents", "fileContent", "file_content", "streamContent", "stream_content"
        ]
    }

    private static func oldTextAliases() -> [String] {
        [
            "oldString", "old_string", "old_str", "oldText", "old_text", "oldContents", "old_contents",
            "old", "search", "searchString", "search_string", "find", "findText", "find_text"
        ]
    }

    private static func newTextAliases() -> [String] {
        [
            "newString", "new_string", "new_str", "newText", "new_text", "newContents", "new_contents",
            "replacement", "replace", "replaceWith", "replace_with", "content"
        ]
    }

    private static func shellCommandAliases() -> [String] {
        ["command", "cmd", "script", "input", "shellCommand", "shell_command", "commandLine", "command_line", "code"]
    }

    private static func shellWorkdirAliases() -> [String] {
        [
            "workingDirectory", "working_directory", "workingDir", "working_dir",
            "workdir", "cwd", "directory", "dir", "path", "root", "rootDir", "root_dir",
            "projectRoot", "project_root"
        ]
    }

    private static func shellExplicitWorkdirAliases() -> [String] {
        shellWorkdirAliases().filter { normalizedName($0) != "path" }
    }

    private static func globPatternAliases(includeQuery: Bool = true) -> [String] {
        var aliases = [
            "globPattern", "glob_pattern", "fileGlob", "file_glob", "filePattern", "file_pattern",
            "includePattern", "include_pattern", "pathPattern", "path_pattern", "pattern", "glob",
            "globPatterns", "glob_patterns", "fileGlobs", "file_globs", "filePatterns", "file_patterns",
            "includePatterns", "include_patterns", "pathPatterns", "path_patterns", "patterns", "globs"
        ]
        if includeQuery {
            aliases.append("query")
        }
        aliases.append(contentsOf: ["include", "includeGlob", "include_glob"])
        return aliases
    }

    private static func globPathAliases() -> [String] {
        [
            "targetDirectory", "target_directory", "targeting", "directory", "dir", "cwd", "workdir",
            "workingDirectory", "working_directory", "path", "root", "rootDir", "root_dir",
            "basePath", "base_path", "searchPath", "search_path",
            "targetDirectories", "target_directories", "directories", "folders", "paths", "roots",
            "rootDirs", "root_dirs", "basePaths", "base_paths", "searchPaths", "search_paths"
        ]
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
