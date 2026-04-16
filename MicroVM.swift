//
//  MicroVM.swift
//  Botparty
//
//  Created by Ben Nolan on 16/04/2026.
//

import Foundation
import Containerization
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import ContainerizationOS

// Custom writer to capture container output
final class OutputWriter: Writer, @unchecked Sendable {
    private let onOutput: @Sendable (Data) -> Void
    
    init(onOutput: @escaping @Sendable (Data) -> Void) {
        self.onOutput = onOutput
    }
    
    func write(_ data: Data) throws {
        onOutput(data)
    }
    
    func close() throws {
        // Nothing to clean up
    }
}

// Custom reader to send input to container
final class InputReader: ReaderStream, @unchecked Sendable {
    private let continuation: AsyncStream<Data>.Continuation
    private let asyncStream: AsyncStream<Data>
    
    init() {
        var cont: AsyncStream<Data>.Continuation!
        asyncStream = AsyncStream<Data> { continuation in
            cont = continuation
        }
        self.continuation = cont
    }
    
    func stream() -> AsyncStream<Data> {
        return asyncStream
    }
    
    func send(_ data: Data) {
        continuation.yield(data)
    }
    
    func close() {
        continuation.finish()
    }
}

class MicroVM {
    private var manager: ContainerManager?
    private var container: LinuxContainer?
    private var isRunning: Bool = false
    private var inputReader: InputReader?
    
    private let memory: UInt64
    private let cpus: Int
    private let diskSize: UInt64
    private let kernelPath: String
    
    var onStatusUpdate: (@Sendable (String) -> Void)?
    var onOutput: (@Sendable (String) -> Void)?
    
    init(memory: Int = 1024, diskSize: Int = 2048, cpus: Int = 2, kernelPath: String) {
        self.memory = UInt64(memory)
        self.diskSize = UInt64(diskSize)
        self.cpus = cpus
        self.kernelPath = kernelPath
    }
    
    func start() async throws {
        guard !isRunning else { return }
        
        onStatusUpdate?("Initializing container manager...")
        
        let kernel = Kernel(
            path: URL(fileURLWithPath: kernelPath),
            platform: .linuxArm
        )
        
        manager = try await ContainerManager(
            kernel: kernel,
            initfsReference: "ghcr.io/apple/containerization/vminit:0.26.5",
            network: nil,
            rosetta: false
        )
        
        guard manager != nil else {
            throw MicroVMError.initializationFailed
        }

        onStatusUpdate?("Creating container...")

        let containerId = "botparty-\(UUID().uuidString.prefix(8))"

        // Set up I/O streams
        let inputReader = InputReader()
        self.inputReader = inputReader
        
        // Capture output handler in a local variable
        let outputHandler = self.onOutput
        
        let stdoutWriter = OutputWriter { data in
            if let output = String(data: data, encoding: .utf8) {
                print(output)
                outputHandler?(output)
            }
        }
        
        let stderrWriter = OutputWriter { data in
            if let output = String(data: data, encoding: .utf8) {
                print(output)
                outputHandler?("ERROR: \(output)")
            }
        }
        
        // Create a local mutable reference to the manager
        var containerManager = self.manager!
        
        container = try await containerManager.create(
            containerId,
            reference: "docker.io/library/alpine:3.16",
            rootfsSizeInBytes: diskSize * 1024 * 1024
        ) { @Sendable config in
            config.cpus = self.cpus
            config.memoryInBytes = self.memory * 1024 * 1024
            config.process.arguments = ["/bin/sh"]
            config.process.workingDirectory = "/"
            config.process.terminal = false
            config.process.stdin = inputReader
            config.process.stdout = stdoutWriter
            config.process.stderr = stderrWriter
        }
        
        guard let container = container else {
            throw MicroVMError.containerCreationFailed
        }
        
        onStatusUpdate?("Starting container...")
        
        try await container.create()
        try await container.start()
        
        isRunning = true
        onStatusUpdate?("Container started successfully")
    }
    
    func send(_ text: String) throws {
        guard isRunning, let inputReader = inputReader else {
            throw MicroVMError.notRunning
        }
        
        guard let data = (text + "\n").data(using: .utf8) else {
            return
        }
        
        inputReader.send(data)
    }
    

    
    func shutdown() {
        guard isRunning else { return }
        
        Task {
            do {
                if let container = container {
                    try await container.stop()
                }
                
                // Clean up input reader
                inputReader?.close()
                inputReader = nil
                
                isRunning = false
                onStatusUpdate?("Container stopped")
            } catch {
                onStatusUpdate?("Error stopping container: \(error)")
            }
        }
    }
    
    deinit {
        shutdown()
    }
}

enum MicroVMError: Error {
    case notRunning
    case timeout
    case initializationFailed
    case containerCreationFailed
}
