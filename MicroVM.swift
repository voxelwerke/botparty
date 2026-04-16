//
//  MicroVM.swift
//  Botparty
//
//  Created by Ben Nolan on 16/04/2026.
//

import Foundation

class MicroVM {
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var outputBuffer: String = ""
    private var isRunning: Bool = false
    
    private let memory: Int
    private let diskSize: Int
    private let cpus: Int
    
    init(memory: Int = 256, diskSize: Int = 1024, cpus: Int = 1) {
        self.memory = memory
        self.diskSize = diskSize
        self.cpus = cpus
    }
    
    func start() async throws {
        guard !isRunning else { return }
        
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/shuru")
        process.arguments = [
            "run",
            "--memory", "\(memory)",
            "--disk-size", "\(diskSize)",
            "--cpus", "\(cpus)"
        ]
        
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        
        self.process = process
        self.inputPipe = inputPipe
        self.outputPipe = outputPipe
        
        // Start reading output
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                self?.outputBuffer += output
            }
        }
        
        try process.run()
        isRunning = true
        
        // Wait for initial boot prompt
        try await wait(pattern: "# ")
    }
    
    func send(_ text: String) throws {
        guard isRunning, let inputPipe = inputPipe else {
            throw MicroVMError.notRunning
        }
        
        let command = text + "\n"
        guard let data = command.data(using: .utf8) else {
            throw MicroVMError.encodingError
        }
        
        inputPipe.fileHandleForWriting.write(data)
    }
    
    func wait(pattern: String = "# ", timeout: TimeInterval = 30.0) async throws {
        let startTime = Date()
        
        while !outputBuffer.contains(pattern) {
            if Date().timeIntervalSince(startTime) > timeout {
                throw MicroVMError.timeout
            }
            
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
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
        
        // Try graceful shutdown
        try? send("poweroff")
        
        // Wait a bit for graceful shutdown
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.process?.terminate()
        }
        
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        isRunning = false
    }
    
    deinit {
        shutdown()
    }
}

enum MicroVMError: Error {
    case notRunning
    case encodingError
    case timeout
    case processError
}
