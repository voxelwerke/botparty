//
//  MicroVM.swift
//  Botparty
//
//  Created by Ben Nolan on 16/04/2026.
//

import Foundation
import Virtualization

class MicroVM: NSObject {
    private var virtualMachine: VZVirtualMachine?
    private var outputBuffer: String = ""
    private var isRunning: Bool = false
    private var serialPort: VZVirtioConsoleDeviceSerialPortConfiguration?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    
    private let memory: UInt64
    private let cpus: Int
    
    var onStatusUpdate: ((String) -> Void)?
    
    init(memory: Int = 1024, diskSize: Int = 1024, cpus: Int = 2) {
        // Ensure minimum requirements (1GB minimum)
        let minMemory = 1024 // MB
        let actualMemory = max(memory, minMemory)
        self.memory = UInt64(actualMemory) * 1024 * 1024 // Convert MB to bytes
        
        let minCPUs = 1
        self.cpus = max(cpus, minCPUs)
        super.init()
    }
    
    func start() async throws {
        guard !isRunning else { return }
        
        onStatusUpdate?("Preparing virtual machine...")
        
        // Create virtual machine configuration
        let configuration = VZVirtualMachineConfiguration()
        
        // Set CPU and memory
        configuration.cpuCount = cpus
        configuration.memorySize = memory
        
        // Configure console for I/O
        let consoleConfig = createConsoleConfiguration()
        configuration.serialPorts = [consoleConfig]
        
        // Configure boot loader - download kernel and initrd if needed
        onStatusUpdate?("Checking kernel files...")
        let kernelURL = try await findKernelImage()
        let initrdURL = try await findInitrdImage()
        
        onStatusUpdate?("Configuring boot loader...")
        
        // VZLinuxBootLoader doesn't support PE32+ EFI kernels
        // We need to use the kernel directly, but Alpine ships EFI format
        // Let's try using it anyway and see what error we get
        configuration.bootLoader = createBootLoader(kernelURL: kernelURL, initialRamdiskURL: initrdURL)
        
        configuration.storageDevices = []
        
        // Entropy device for random number generation
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        
        // Memory balloon device
        configuration.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        
        // Platform (required for EFI boot)
        #if arch(arm64)
        let platform = VZGenericPlatformConfiguration()
        configuration.platform = platform
        #endif
        
        // Validate configuration
        onStatusUpdate?("Validating configuration...")
        do {
            try configuration.validate()
            onStatusUpdate?("Configuration validated successfully")
        } catch {
            onStatusUpdate?("Validation error: \(error.localizedDescription)")
            throw error
        }
        
        // Create and start the virtual machine
        let vm = VZVirtualMachine(configuration: configuration)
        vm.delegate = self
        self.virtualMachine = vm
        
        // Start reading output
        if let outputPipe = outputPipe {
            outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                    Task { @MainActor in
                        self?.outputBuffer += output
                        self?.onStatusUpdate?("Console: \(output)")
                    }
                }
            }
        }
        
        // Start the VM
        onStatusUpdate?("Starting virtual machine...")
        onStatusUpdate?("CPU: \(configuration.cpuCount), Memory: \(configuration.memorySize / 1024 / 1024)MB")
        onStatusUpdate?("Kernel: \(kernelURL.lastPathComponent)")
        onStatusUpdate?("Initrd: \(initrdURL.lastPathComponent)")
        
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                vm.start { result in
                    switch result {
                    case .success:
                        continuation.resume()
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            }
            onStatusUpdate?("VM start() completed successfully")
        } catch {
            onStatusUpdate?("VM start() failed: \(error.localizedDescription)")
            if let nsError = error as NSError? {
                onStatusUpdate?("Error domain: \(nsError.domain), code: \(nsError.code)")
                onStatusUpdate?("Error info: \(nsError.userInfo)")
            }
            throw error
        }
        
        isRunning = true
        onStatusUpdate?("VM started, waiting for boot...")
        
        // Wait for initial boot prompt
        try await wait(pattern: "# ")
    }
    
    private func createConsoleConfiguration() -> VZSerialPortConfiguration {
        let consoleConfiguration = VZVirtioConsoleDeviceSerialPortConfiguration()
        
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        
        self.inputPipe = inputPipe
        self.outputPipe = outputPipe
        
        let stdioAttachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: inputPipe.fileHandleForReading,
            fileHandleForWriting: outputPipe.fileHandleForWriting
        )
        
        consoleConfiguration.attachment = stdioAttachment
        
        return consoleConfiguration
    }
    
    private func createBootLoader(kernelURL: URL, initialRamdiskURL: URL) -> VZBootLoader {
        let bootLoader = VZLinuxBootLoader(kernelURL: kernelURL)
        bootLoader.initialRamdiskURL = initialRamdiskURL
        bootLoader.commandLine = "console=hvc0 root=/dev/ram0 rw rdinit=/sbin/init"
        
        return bootLoader
    }
    
    private func getCacheDirectory() -> URL {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let botpartyCache = cacheDir.appendingPathComponent("Botparty", isDirectory: true)
        
        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: botpartyCache, withIntermediateDirectories: true)
        
        return botpartyCache
    }
    
    private func downloadFileIfNeeded(from urlString: String, to destinationURL: URL) async throws {
        // Check if file already exists
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            return
        }
        
        guard let url = URL(string: urlString) else {
            throw MicroVMError.invalidURL
        }
        
        let fileName = url.lastPathComponent
        onStatusUpdate?("Downloading \(fileName)...")
        
        // Create a delegate to track download progress
        let delegate = DownloadDelegate(fileName: fileName, onStatusUpdate: onStatusUpdate)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        
        let (tempURL, response) = try await session.download(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw MicroVMError.downloadFailed
        }
        
        // Move downloaded file to destination
        try FileManager.default.moveItem(at: tempURL, to: destinationURL)
        
        onStatusUpdate?("Downloaded \(fileName)")
    }
    
    private func findKernelImage() async throws -> URL {
        let cacheDir = getCacheDirectory()
        let kernelURL = cacheDir.appendingPathComponent("vmlinuz-lts")
        
        try await downloadFileIfNeeded(
            from: "https://dl-cdn.alpinelinux.org/alpine/v3.16/releases/aarch64/netboot-3.16.9/vmlinuz-lts",
            to: kernelURL
        )
        
        return kernelURL
    }
    
    private func findInitrdImage() async throws -> URL {
        let cacheDir = getCacheDirectory()
        let initrdURL = cacheDir.appendingPathComponent("initramfs-lts")
        
        try await downloadFileIfNeeded(
            from: "https://dl-cdn.alpinelinux.org/alpine/v3.16/releases/aarch64/netboot-3.16.9/initramfs-lts",
            to: initrdURL
        )
        
        return initrdURL
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
        
        // Stop the VM
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self, let vm = self.virtualMachine else { return }
            
            if vm.canStop {
                vm.stop { error in
                    if let error = error {
                        print("Error stopping VM: \(error)")
                    }
                }
            }
        }
        
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        isRunning = false
    }
    
    deinit {
        shutdown()
    }
}

// MARK: - VZVirtualMachineDelegate
extension MicroVM: VZVirtualMachineDelegate {
    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        onStatusUpdate?("VM stopped")
        isRunning = false
    }
    
    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        onStatusUpdate?("VM error: \(error.localizedDescription)")
        isRunning = false
    }
}

enum MicroVMError: Error {
    case notRunning
    case encodingError
    case timeout
    case invalidURL
    case downloadFailed
}
// MARK: - Download Delegate
private class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let fileName: String
    let onStatusUpdate: ((String) -> Void)?
    
    init(fileName: String, onStatusUpdate: ((String) -> Void)?) {
        self.fileName = fileName
        self.onStatusUpdate = onStatusUpdate
        super.init()
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let percentage = Int(progress * 100)
        onStatusUpdate?("Downloading \(fileName): \(percentage)%")
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Download complete - handled in the main function
    }
}

