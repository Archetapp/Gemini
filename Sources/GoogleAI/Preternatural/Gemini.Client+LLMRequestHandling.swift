//
// Copyright (c) Vatsal Manot
//

import CoreMI
import CorePersistence
import LargeLanguageModels
import NetworkKit
import Swallow

extension Gemini.Client: LLMRequestHandling {
    public var _availableModels: [ModelIdentifier]? {
        Gemini.Model.allCases.map({ $0.__conversion() })
    }
    
    public func complete<Prompt: AbstractLLM.Prompt>(
        prompt: Prompt,
        parameters: Prompt.CompletionParameters
    ) async throws -> Prompt.Completion {
        let _completion: Any
        
        switch prompt {
            case let prompt as AbstractLLM.TextPrompt:
                _completion = try await _complete(
                    prompt: prompt,
                    parameters: try cast(parameters)
                )
            case let prompt as AbstractLLM.ChatPrompt:
                _completion = try await _complete(
                    prompt: prompt,
                    parameters: try cast(parameters)
                )
            default:
                throw LLMRequestHandlingError.unsupportedPromptType(Prompt.self)
        }
        
        return try cast(_completion)
    }
    
    private func _complete(
        prompt: AbstractLLM.TextPrompt,
        parameters: AbstractLLM.TextCompletionParameters
    ) async throws -> AbstractLLM.TextCompletion {
        let modelName = try await _model(from: prompt).rawValue
        let content: [ModelContent] = try _modelContent(from: prompt)
        let config: GenerationConfig = _makeGenerationConfig(parameters: parameters)
        
        let model = GenerativeModel(
            name: modelName,
            apiKey: configuration.apiKey,
            generationConfig: config
        )
        let response = try await model.generateContent(content)
        
        return AbstractLLM.TextCompletion(
            prefix: .init(_lazy: prompt.prefix),
            text: response.text ?? ""
        )
    }
    
    private func _complete(
        prompt: AbstractLLM.ChatPrompt,
        parameters: AbstractLLM.ChatCompletionParameters
    ) async throws -> AbstractLLM.ChatCompletion {
        let model: Gemini.Model = try await _model(from: prompt)
        
        let (systemInstruction, modelContent) = try await _makeSystemInstructionAndModelContent(messages: prompt.messages)
        
        let generativeModel = GenerativeModel(
            name: model.rawValue,
            apiKey: configuration.apiKey,
            generationConfig: _makeGenerationConfig(messages: prompt.messages, parameters: parameters),
            systemInstruction: systemInstruction
        )
        
        let response: GenerateContentResponse = try await generativeModel.generateContent(modelContent)
        let firstCandidate: CandidateResponse = try response.candidates.toCollectionOfOne().value // TODO: Add support for batch generation
        let completion = AbstractLLM.ChatCompletion(
            prompt: prompt,
            message: try AbstractLLM.ChatMessage(_from: firstCandidate.content),
            stopReason: try AbstractLLM.ChatCompletion.StopReason(_from: firstCandidate.finishReason.unwrap())
        )
        
        return completion
    }
    
    public func _complete(
        _ messages: [AbstractLLM.ChatMessage],
        functions: [AbstractLLM.ChatFunctionDefinition],
        model: Gemini.Model,
        as type: AbstractLLM.ChatFunctionCall.Type
    ) async throws -> [FunctionCall] {
        
        //FIXME: This should ideally be AbstractLLM.ChatFunctionCall.

        let service = GenerativeAIService(
            apiKey: configuration.apiKey,
            urlSession: .shared
        )
        
        let functionDeclarations: [FunctionDeclaration] = functions.map { function in
            FunctionDeclaration(
                name: function.name.rawValue,
                description: function.context,
                parameters: [
                    function.name.rawValue == "set_light_color" ? "rgb_hex" : "dummy": Schema(
                        type: .string,
                        description: function.parameters.properties?.first?.value.description ?? "Placeholder parameter"
                    )
                ],
                requiredParameters: function.name.rawValue == "set_light_color" ? ["rgb_hex"] : nil
            )
        }
        
        let systemMessage = messages.first { $0.role == .system }
        let systemInstruction = ModelContent(
            role: "system",
            parts: [.text(try systemMessage?.content._stripToText() ?? "")]
        )
        
        let userMessages = messages.filter { $0.role != .system }
        let userContent = userMessages.map { message in
            ModelContent(
                role: "user",
                parts: [.text(try! message.content._stripToText())]
            )
        }

        let request = GenerateContentRequest(
            model: "models/" + model.rawValue,
            contents: userContent,
            generationConfig: nil,
            safetySettings: nil,
            tools: [Tool(functionDeclarations: functionDeclarations)],
            toolConfig: ToolConfig(functionCallingConfig: FunctionCallingConfig(mode: .auto)),
            systemInstruction: systemInstruction,
            isStreaming: false,
            options: RequestOptions()
        )
        
        //FIXME: This should ideally be AbstractLLM.ChatFunctionCall.

        let response = try await service.loadRequest(request: request)
        
        dump(response)
        
        let functionCalls = response.candidates.first?.content.parts.compactMap { part -> FunctionCall? in
            if case .functionCall(let functionCall) = part {
                return functionCall
            }
            return nil
        } ?? []

        return functionCalls
    }
}

extension Gemini.Client {
    private func _makeGenerationConfig(
        messages: [AbstractLLM.ChatMessage],
        parameters: AbstractLLM.ChatCompletionParameters
    ) -> GenerationConfig {
        let temperature: Float? = parameters.temperatureOrTopP?.temperature.map(Float.init)
        let topP: Float? = parameters.temperatureOrTopP?.topProbabilityMass.map(Float.init)
        let maxOutputTokens: Int? = parameters.tokenLimit == .max ? nil : parameters.tokenLimit?.fixedValue
        
        return GenerationConfig(
            temperature: temperature,
            topP: topP,
            maxOutputTokens: maxOutputTokens,
            stopSequences: parameters.stops
        )
    }
    
    private func _makeSystemInstructionAndModelContent(
        messages: [AbstractLLM.ChatMessage]
    ) async throws -> (systemInstruction: ModelContent?, content: [ModelContent]) {
        var messages: [AbstractLLM.ChatMessage] = messages
        var systemInstruction: ModelContent?
        
        if messages.first?.role == .system {
            let systemMessage: AbstractLLM.ChatMessage = messages.removeFirst()
            
            systemInstruction = try await ModelContent(_from: systemMessage)
        }
        
        var content: [ModelContent] = []
        
        for message in messages {
            try  _tryAssert(message.role != .system)
            
            content.append(try await ModelContent(_from: message))
        }
        
        return (systemInstruction, content)
    }
    
    private func _modelContent(
        from prompt: AbstractLLM.TextPrompt
    ) throws -> [ModelContent] {
        let promptText = try prompt.prefix.promptLiteral._stripToText()
        
        return [ModelContent(role: "user", parts: promptText)]
    }
    
    private func _makeGenerationConfig(
        parameters: AbstractLLM.TextCompletionParameters
    ) -> GenerationConfig {
        let temperature: Float? = parameters.temperatureOrTopP?.temperature.map(Float.init)
        let topP: Float? = parameters.temperatureOrTopP?.topProbabilityMass.map(Float.init)
        let maxOutputTokens: Int? = parameters.tokenLimit == .max ? nil : parameters.tokenLimit.fixedValue
        
        return GenerationConfig(
            temperature: temperature,
            topP: topP,
            maxOutputTokens: maxOutputTokens,
            stopSequences: parameters.stops
        )
    }
    
    private func _model(
        from prompt: any AbstractLLM.Prompt
    ) async throws -> Gemini.Model {
        do {
            guard let modelIdentifierScope: ModelIdentifierScope = prompt.context.get(\.modelIdentifier) else {
                return Gemini.Model.gemini_1_5_pro_latest
            }
            
            let modelIdentifier: ModelIdentifier = try modelIdentifierScope._oneValue
            
            return try Gemini.Model(from: modelIdentifier)
        } catch {
            runtimeIssue("Failed to resolve model identifier.")
            
            throw error
        }
    }
}

extension AbstractLLM.ChatFunctionDefinition {
    func toGeminiFunctionDeclaration() -> FunctionDeclaration {
        func schemaToGeminiSchema(_ schema: JSONSchema) -> Schema {
            switch schema.type {
                case .string:
                    return Schema(
                        type: .string,
                        description: schema.description
                    )
                case .object:
                    var parameters: [String: Schema] = [:]
                    if let properties = schema.properties {
                        for (key, value) in properties {
                            parameters[key] = schemaToGeminiSchema(value)
                        }
                    }
                    return Schema(
                        type: .object,
                        description: schema.description,
                        properties: parameters,
                        requiredProperties: schema.required
                    )
                    // Add other type conversions as needed
                default:
                    return Schema(type: .string, description: "Fallback type") // Default fallback
            }
        }
        
        return FunctionDeclaration(
            name: name.rawValue,
            description: context,
            parameters: schemaToGeminiSchema(parameters).properties,
            requiredParameters: parameters.required
        )
    }
}

extension AbstractLLM.ChatRole {
    // Convert AbstractLLM role to Gemini role string
    func toGeminiRole() -> String {
        switch self {
            case .system:
                return "systemInstruction"  // Special case for Gemini
            case .user:
                return "user"
            case .assistant:
                return "model"  // Gemini uses "model" instead of "assistant"
            case .other(let value):
                return value.rawValue
        }
    }
}

