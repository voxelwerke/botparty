//
//  Agent.swift
//  Botparty
//
//  Created by Ben Nolan on 16/04/2026.
//

import Foundation
import SwiftData
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import MLXOptimizers
import SwiftUI
import Tokenizers


@Model
class Agent {
    var name: String
    var responses: [String] = []
    var statusMessage: String = "Ready"
    var loadingProgress: Double = 0.0
    var createdAt: Date
    
    // Transient properties (not persisted)
    @Transient var isRunning: Bool = false
    
    init(name: String = "Agent \(Date().formatted(date: .omitted, time: .shortened))") {
        self.name = name
        self.createdAt = Date()
    }
    
    func play() async {
        await run()
    }
    
    func pause() {
        // Pause functionality - for now just stops by setting isRunning to false
        isRunning = false
        statusMessage = "Paused"
    }
    
    func run() async {
        isRunning = true
        responses = []
        loadingProgress = 0.0
        
        do {
            statusMessage = "Loading model..."
            
            let model = try await loadModel(id: "mlx-community/Qwen3-4B-4bit") { progress in
                self.loadingProgress = progress.fractionCompleted
                self.statusMessage = "Loading model: \(Int(progress.fractionCompleted * 100))%"
            }
            
            statusMessage = "Model loaded, starting session..."
            let session = ChatSession(model)
            
            statusMessage = "Asking about San Francisco..."
            let response1 = try await session.respond(to: "What are two things to see in San Francisco?")
            responses.append(response1)
            
            statusMessage = "Asking about restaurants..."
            let response2 = try await session.respond(to: "How about a great place to eat?")
            responses.append(response2)
            
            statusMessage = "Complete!"
            
        } catch {
            responses.append("Error: \(error.localizedDescription)")
            statusMessage = "Error: \(error.localizedDescription)"
        }
        
        isRunning = false
    }
}
