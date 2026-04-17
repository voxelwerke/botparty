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


@Model
class Agent {
    var name: String
    var responses: [String] = []
    var statusMessage: String = "Ready"
    var createdAt: Date
    var systemPrompt: String = """
    You are a Linux exploration agent in a root shell. 
    STRICT RULES:
    1. Output ONLY a single shell command per turn.
    2. NO markdown, NO code blocks, NO explanations.
    3. If finished, exit the shell.
    """
    
    // Transient properties (not persisted)
    @Transient var isRunning: Bool = false
    @Transient var microVM: MicroVM?
    
    init(name: String = "Agent \(Date().formatted(date: .omitted, time: .shortened))") {
        self.name = name
        self.createdAt = Date()
    }
    
    func play() async {
        await run()
    }
    
    func pause() {
        // Pause functionality - stops execution and shuts down VM
        isRunning = false
        statusMessage = "Paused"
        microVM?.shutdown()
        microVM = nil
    }
    
    @MainActor
    func run() async {
        isRunning = true
        responses = []
        
        do {
            // Step 1: Create and start MicroVM
            self.statusMessage = "Starting MicroVM..."
            
            guard let kernelPath = Bundle.main.path(forResource: "vmlinux", ofType: nil) else {
                throw NSError(domain: "Agent", code: 1, userInfo: [NSLocalizedDescriptionKey: "vmlinux kernel file not found"])
            }
            let vm = MicroVM(memory: 256, diskSize: 1024, cpus: 1, kernelPath: kernelPath)
            vm.onStatusUpdate = { [weak self] status in
//                self?.statusMessage = status
                self?.responses.append(status)
            }
            self.microVM = vm
            
            try await vm.start()
            self.statusMessage = "MicroVM started"
            
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
            
            // responses.append("VM Output: \(output1)")
            
            // Step 3: Load model
            responses.append("Loading AI...")
            
            self.statusMessage = "Loading AI..."
            
            let container = try await ModelManager.shared.getModel { progress in
                self.statusMessage = "Loading model: \(Int(progress.fractionCompleted * 100))%"
            }
            
            let instructions = self.systemPrompt + "\n"
            print(instructions)
            
            let session = ChatSession(container, instructions: instructions)
            
            // Step 4: Run AI tasks
            self.statusMessage = "Running..."

            print("DEBUG: About to get first AI response")
            var command = try await session.respond(to: "The system booted, begin")
            print("DEBUG: Got command: \(command)")
            responses.append("AI: \(command)")

            while (self.isRunning) {
//                statusMessage = "Running \(command)"

                try await vm.sendline(command)
                try await vm.expect("#> ")
                
                // Get response from the VM
                let shellResult = vm.before
                responses.append("VM: \(shellResult)")

                // Get next command
                command = try await session.respond(to: shellResult)
                responses.append("AI: \(command)")
                
                // If exit, then exit
                if (command.hasPrefix("exit")) {
                    self.isRunning = false
                }
                
                // Sleep for 500ms
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            
            // Step 5: Clean up
            statusMessage = "Exiting..."
            vm.shutdown()
            
            statusMessage = "Exited"
            
        } catch {
            responses.append("Error: \(error.localizedDescription)")
            statusMessage = "Error: \(error.localizedDescription)"
            microVM?.shutdown()
            microVM = nil
        }
        
        isRunning = false
    }
}
