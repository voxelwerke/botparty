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
    var createdAt: Date
    
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
    
    func run() async {
        isRunning = true
        responses = []
        
        do {
            // Step 1: Create and start MicroVM
            statusMessage = "Starting MicroVM..."
            
            guard let kernelPath = Bundle.main.path(forResource: "vmlinux", ofType: nil) else {
                throw NSError(domain: "Agent", code: 1, userInfo: [NSLocalizedDescriptionKey: "vmlinux kernel file not found"])
            }
            let vm = MicroVM(memory: 256, diskSize: 1024, cpus: 1, kernelPath: kernelPath)
            vm.onStatusUpdate = { [weak self] status in
                self?.statusMessage = status
                self?.responses.append(status)
            }
            self.microVM = vm
            
            try await vm.start()
            responses.append("MicroVM started successfully")
            
            // Step 2: Test VM with a simple command
            statusMessage = "Testing VM..."
            
            try vm.send("echo 'Hello from MicroVM'")
            try vm.send("uname -a")
            // try await vm.wait(pattern: "# ")
            // let output1 = vm.readOutput()
            // responses.append("VM Output: \(output1)")
            
            // Step 3: Load model
            statusMessage = "Loading model..."
            
            let model = try await loadModel(id: "mlx-community/Qwen3-4B-4bit") { progress in
                self.statusMessage = "Loading model: \(Int(progress.fractionCompleted * 100))%"
            }
            
            statusMessage = "Model loaded, starting session..."
            let session = ChatSession(model)
            
            // Step 4: Run AI tasks
            statusMessage = "Asking about San Francisco..."
            let response1 = try await session.respond(to: "What are two things to see in San Francisco?")
            responses.append("AI: \(response1)")
            
            statusMessage = "Asking about restaurants..."
            let response2 = try await session.respond(to: "How about a great place to eat?")
            responses.append("AI: \(response2)")
            
            // Step 5: Clean up
            statusMessage = "Shutting down VM..."
            vm.shutdown()
            
            statusMessage = "Complete!"
            
        } catch {
            responses.append("Error: \(error.localizedDescription)")
            statusMessage = "Error: \(error.localizedDescription)"
            microVM?.shutdown()
            microVM = nil
        }
        
        isRunning = false
    }
}
