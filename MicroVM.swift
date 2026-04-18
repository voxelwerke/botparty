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
import vmnet

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
    
    // Pexpect State
    private(set) var before: String = ""
    private(set) var after: String = ""
    private var buffer: String = ""
    private var bufferUpdateStream: AsyncStream<Void>?
    private var bufferUpdateContinuation: AsyncStream<Void>.Continuation?

    init(memory: Int = 1024, diskSize: Int = 2048, cpus: Int = 2, kernelPath: String) {
        self.memory = UInt64(memory)
        self.diskSize = UInt64(diskSize)
        self.cpus = cpus
        self.kernelPath = kernelPath
    }
    
    func start() async throws {
        guard !isRunning else { return }
        
        // Set up buffer update stream
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        self.bufferUpdateStream = stream
        self.bufferUpdateContinuation = continuation
        
        onStatusUpdate?("Loading MicroVM...")
        
        let kernel = Kernel(
            path: URL(fileURLWithPath: kernelPath),
            platform: .linuxArm
        )
        
        // Enable NAT networking for internet access
        let network = try await VmnetNetwork(mode: .VMNET_SHARED_MODE)
        
        manager = try await ContainerManager(
            kernel: kernel,
            initfsReference: "ghcr.io/apple/containerization/vminit:0.26.5",
            network: network,
            rosetta: false
        )
        
        guard manager != nil else {
            throw MicroVMError.initializationFailed
        }

        let containerId = "botparty-\(UUID().uuidString.prefix(8))"

        // Set up I/O streams
        let inputReader = InputReader()
        self.inputReader = inputReader
        
        let stdoutWriter = OutputWriter { [weak self] data in
            guard let self = self, let output = String(data: data, encoding: .utf8) else { return }
//            print("OUTPUT: \(output.debugDescription)")
            
            // Append to internal buffer and notify any waiting expect calls
            self.buffer += output
            self.bufferUpdateContinuation?.yield(())
        }

        let stderrWriter = OutputWriter { data in
            if let output = String(data: data, encoding: .utf8) {
                print(output)
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
            config.process.terminal = true
            config.process.stdin = inputReader
            config.process.stdout = stdoutWriter
            // config.process.stderr = stderrWriter
        }
        
        guard let container = container else {
            throw MicroVMError.containerCreationFailed
        }
        
        try await container.create()
        try await container.start()
        
        isRunning = true
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
    
    /// Sends a command and waits for the newline echo, so .before won't include the command
    func sendline(_ text: String, timeout: TimeInterval = 10.0) async throws {
        try send(text)
        // Wait for the newline after the command echo
        // Terminals typically use \r\n (CRLF) instead of just \n
        try await expect("\r\n", timeout: timeout)
    }
    
    func flush() async {
        // Sleep for 500ms
        try? await Task.sleep(nanoseconds: 500_000_000)

        // Discard everything currently stored
        self.before = ""
        self.after = ""
        self.buffer = ""
        
        // Sleep for 50ms
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    
    /// Logic for pexpect: waits until the buffer contains the pattern
    func expect(_ pattern: String, timeout: TimeInterval = 10.0) async throws {
        let startTime = Date()
        
        // Check if pattern is already in buffer
        if let range = buffer.range(of: pattern) {
            before = String(buffer[..<range.lowerBound])
            after = String(buffer[range])
            buffer = String(buffer[range.upperBound...])
            return
        }
        
        guard let stream = bufferUpdateStream else {
            throw MicroVMError.notRunning
        }
        
        // Wait for buffer updates
        for await _ in stream {
            // Check if pattern is now in buffer
            if let range = buffer.range(of: pattern) {
                before = String(buffer[..<range.lowerBound])
                after = String(buffer[range])
                buffer = String(buffer[range.upperBound...])
                return
            }
            
            // Check timeout
            if Date().timeIntervalSince(startTime) > timeout {
                throw MicroVMError.timeout
            }
        }
        
        // Stream ended without finding pattern
        throw MicroVMError.notRunning
    }
    
    func shutdown() {
        guard isRunning else { return }
        
        Task {
            do {
                isRunning = false

                if let container = container {
                    try await container.stop()
                }
                
                // Clean up input reader
                inputReader?.close()
                inputReader = nil
                
                // Clean up buffer update stream
                bufferUpdateContinuation?.finish()
                bufferUpdateContinuation = nil
                bufferUpdateStream = nil
                
                onStatusUpdate?("MicroVM stopped")
            } catch {
                onStatusUpdate?("Error stopping MicroVM: \(error)")
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
