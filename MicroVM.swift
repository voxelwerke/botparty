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

class MicroVM {
    private var manager: ContainerManager?
    private var container: LinuxContainer?
    private var outputBuffer: String = ""
    private var isRunning: Bool = false
    
    private let memory: UInt64
    private let cpus: Int
    private let diskSize: UInt64
    private let kernelPath: String
    
    var onStatusUpdate: ((String) -> Void)?
    
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
        
        // Choose network implementation based on macOS version
        let network: Network?
        if #available(macOS 26, *) {
            network = try? VmnetNetwork()
        } else {
            network = nil
        }
        
        manager = try await ContainerManager(
            kernel: kernel,
            initfsReference: "ghcr.io/apple/containerization/vminit:0.26.5",
            network: network,
            rosetta: false
        )
        
        guard manager != nil else {
            throw MicroVMError.initializationFailed
        }

        onStatusUpdate?("Creating container...")

        let containerId = "botparty-\(UUID().uuidString.prefix(8))"

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
        guard isRunning, container != nil else {
            throw MicroVMError.notRunning
        }
        
        // Note: Container I/O would need to be configured through terminal
        // This is a placeholder for the interface
        outputBuffer += "Command: \(text)\n"
    }
    
    func wait(pattern: String = "# ", timeout: TimeInterval = 30.0) async throws {
        let startTime = Date()
        
        while !outputBuffer.contains(pattern) {
            if Date().timeIntervalSince(startTime) > timeout {
                throw MicroVMError.timeout
            }
            
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }
    
    func readOutput() -> String {
        let output = outputBuffer
        outputBuffer = ""
        return output
    }
    
    func readOutputSinceLastRead() -> String {
        return readOutput()
    }
    
    func shutdown() {
        guard isRunning else { return }
        
        Task {
            do {
                if let container = container {
                    try await container.stop()
                }
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
