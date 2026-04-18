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
import MLX
import MLXLLM
import MLXLMCommon

actor ModelManager {
    static let shared = ModelManager()
    
    private var modelContainer: MLXLMCommon.ModelContainer?
    private var modelId = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
    
    private init() {}

    func getModel(progressHandler: @escaping (Progress) -> Void) async throws -> MLXLMCommon.ModelContainer {
        // Return existing model if already loaded
        if let container = modelContainer {
            return container
        }
        
        // Load the model
        let container = try await loadModelContainer(id: modelId) { progress in
            progressHandler(progress)
        }
        
        self.modelContainer = container
        return container
    }
}


enum MessageType: Codable {
    case ai
    case vm
    case system
}

struct Message: Codable, Identifiable {
    let id: UUID
    let type: MessageType
    let content: String
    
    init(type: MessageType, content: String) {
        self.id = UUID()
        self.type = type
        self.content = content
    }
}

@Model
class Agent {
    var name: String
    var createdAt: Date
    var systemPrompt: String = """
    You are a ghost in a shell. 
    
    STRICT RULES:
    1. Output ONLY a single shell command per turn.
    2. NO markdown, NO code blocks, NO explanations.
    3. If finished, exit the shell.
    """
    
    var responses: [String] = []
    var messages: [Message] = []
    var statusMessage: String = "Paused"
    
    // Transient properties (not persisted - reset on each launch)
    @Transient var isRunning: Bool = false
    @Transient var microVM: MicroVM?
    @Transient var chatSession: ChatSession?
    
    init(name: String = "Agent \(Date().formatted(date: .omitted, time: .shortened))") {
        self.name = name
        self.createdAt = Date()
    }
    
    func play() async {
        self.isRunning = true
        await run()
    }
    
    func stop() {
        // Pause functionality - stops execution and shuts down VM
        isRunning = false
        statusMessage = "Paused"
        microVM?.shutdown()
        microVM = nil
        chatSession = nil
        
        // CRITICAL: Clear MLX GPU cache to prevent memory leak
        MLX.GPU.clearCache()
    }
    
    func run() async {
        isRunning = true
        
        await MainActor.run {
            self.responses = []
            self.messages = []
            self.messages.append(Message(type: .system, content: "Loading AI..."))
            self.statusMessage = "Loading AI..."
        }
        
        do {
            
            let container = try await ModelManager.shared.getModel { progress in
                if (progress.fractionCompleted < 0.8) {
                    Task { @MainActor in
                        self.statusMessage = "Loading model: \(Int(progress.fractionCompleted * 100))%"
                    }
                }
            }

            // Step 1: Create and start MicroVM
            await MainActor.run {
                self.statusMessage = "Loading MicroVM..."
            }
            
            guard let kernelPath = Bundle.main.path(forResource: "vmlinux", ofType: nil) else {
                throw NSError(domain: "Agent", code: 1, userInfo: [NSLocalizedDescriptionKey: "vmlinux kernel file not found"])
            }
            let vm = MicroVM(memory: 256, diskSize: 1024, cpus: 1, kernelPath: kernelPath)
            vm.onStatusUpdate = { [weak self] status in
                Task { @MainActor in
                    self?.messages.append(Message(type: .system, content: status))
                }
            }
            self.microVM = vm
            
            try await vm.start()
            await MainActor.run {
                self.statusMessage = "MicroVM started"
            }
            
            // Step 2: Test VM with a simple command

            try vm.send("PS1=\"#> \"")
            await vm.flush()

            try await vm.sendline("echo 'Hello from MicroVM'")
            try await vm.expect("#> ")
            print("result \(vm.before)")

            // Sendline is send + expect
            try await vm.sendline("uname -a")
            try await vm.expect("#> ")
            print("result \(vm.before)")
            
            
            let instructions = self.systemPrompt + "\n"
            print(instructions)
            
            // Create session with generation parameters to prevent infinite loops
            var generateParams = GenerateParameters()
            generateParams.maxTokens = 100  // Limit response length
            generateParams.temperature = 0.7
            
            self.chatSession = ChatSession(container, instructions: instructions, generateParameters: generateParams)
            
            // Step 4: Run AI tasks
            await MainActor.run {
                self.statusMessage = "Running..."
            }

            print("DEBUG: About to get first AI response")
            guard self.isRunning, let session = self.chatSession else { return }
            
            // Get first command off MainActor to prevent UI blocking
            let firstCommand = try await Task.detached {
                try await session.respond(to: "The system booted, begin")
            }.value
            
            print("DEBUG: Got command: \(firstCommand)")
            await MainActor.run {
                self.messages.append(Message(type: .ai, content: firstCommand))
            }
            var command = firstCommand

            while self.isRunning {
                try await vm.sendline(command)
                try await vm.expect("#> ")
                
                // Get response from the VM
                let bytes = finalizeShellBytes(vm.before)
                let shellResult = String(data: bytes, encoding: .utf8)!
                await MainActor.run {
                    self.messages.append(Message(type: .vm, content: shellResult))
                }

                // Sleep for 500ms
                try? await Task.sleep(nanoseconds: 500_000_000)

                // Check if still running before calling AI
                guard self.isRunning, let session = self.chatSession else { break }

                // Get next command off MainActor to prevent blocking
                let nextCommand = try await Task.detached {
                    try await session.respond(to: shellResult)
                }.value
                
                await MainActor.run {
                    self.messages.append(Message(type: .ai, content: nextCommand))
                }
                command = nextCommand
                
                // If exit, then exit
                if command.hasPrefix("exit") {
                    self.isRunning = false
                }
            }
            
            vm.shutdown()
            await MainActor.run {
                self.statusMessage = "Paused"
            }
            chatSession = nil
            
            // Clear MLX cache after session completes
            MLX.GPU.clearCache()
            
        } catch {
            await MainActor.run {
                self.messages.append(Message(type: .system, content: "Error: \(error.localizedDescription)"))
                self.statusMessage = "Error: \(error.localizedDescription)"
            }
            microVM?.shutdown()
            microVM = nil
            chatSession = nil
            MLX.GPU.clearCache()
        }
        
        isRunning = false
    }
}
