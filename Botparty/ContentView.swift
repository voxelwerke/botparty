//
//  ContentView.swift
//  Botparty
//
//  Created by Ben Nolan on 16/04/2026.
//

import SwiftUI
import SwiftData


enum SidebarSelection: Hashable {
    case thePool
    case agent(Agent)
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Agent.createdAt, order: .reverse) private var agents: [Agent]
    @State private var selectedItem: SidebarSelection? = nil
    @State private var showInspector: Bool = true
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // Sidebar
            List(selection: $selectedItem) {
                // Pool entry at the top
                HStack {
                    Image(systemName: "books.vertical")
                        .foregroundStyle(.secondary)
                    Text("Pool")
                        .font(.headline)
                }
                .tag(SidebarSelection.thePool)
                .listRowBackground(
                    selectedItem == .thePool ? Color.gray.opacity(0.2) : Color.clear
                )
                
                Divider()
                
                // Agent list
                ForEach(agents) { agent in
                    AgentSidebarRow(agent: agent)
                        .tag(SidebarSelection.agent(agent))
                        .listRowBackground(
                            selectedItem == .agent(agent) ? Color.gray.opacity(0.2) : Color.clear
                        )
                }
            }
            .navigationTitle("Agents")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: createNewAgent) {
                        Image(systemName: "plus")
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 250)
        } detail: {
            // Detail View
            if let selectedItem = selectedItem {
                switch selectedItem {
                case .thePool:
                    ThePoolView()
                case .agent(let agent):
                    AgentDetailView(agent: agent, showInspector: $showInspector)
                }
            } else {
                ContentUnavailableView(
                    "No Selection",
                    systemImage: "robot",
                    description: Text("Select an agent or browse Pool")
                )
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
    
    private func createNewAgent() {
        let newAgent = Agent()
        modelContext.insert(newAgent)
        selectedItem = .agent(newAgent)
        
        // Auto-launch the new agent
        Task {
            // Stop all paused agents
            for agent in agents where agent.state == .paused {
                agent.stop()
            }
            await newAgent.play()
        }
    }
    
    private func deleteAgent(_ agent: Agent) {
        if case .agent(let selectedAgent) = selectedItem, selectedAgent == agent {
            selectedItem = nil
        }
        modelContext.delete(agent)
    }
}

// Sidebar Row Component
struct AgentSidebarRow: View {
    @Bindable var agent: Agent
    @Environment(\.modelContext) private var modelContext
    @Query private var allAgents: [Agent]
    @State private var isEditingName: Bool = false
    @FocusState private var isTextFieldFocused: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if isEditingName {
                    TextField("Agent name", text: $agent.name, onCommit: {
                        isEditingName = false
                    })
                    .font(.headline)
                    .textFieldStyle(.plain)
                    .focused($isTextFieldFocused)
                    .onAppear {
                        isTextFieldFocused = true
                    }
                } else {
                    Text(agent.name)
                        .font(.headline)
                        .onTapGesture(count: 2) {
                            isEditingName = true
                        }
                }
                
                Spacer()
                
                AgentControlButtons(agent: agent)
            }
            
            HStack {
                Text(agent.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .listRowBackground(isEditingName ? Color.clear : nil)
        .contextMenu {
            Button {
                isEditingName = true
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            
            Divider()

            Button {
                duplicateAgent()
            } label: {
                Label("Duplicate", systemImage: "doc.on.doc")
            }
            
            
            Button {
                reproduceAgent()
            } label: {
                Label("Reproduce", systemImage: "square.and.arrow.up")
            }
            
            Divider()

            Button {
                releaseAgent()
            } label: {
                Label("Release", systemImage: "square.and.arrow.up.on.square")
            }
            
            
            Button(role: .destructive) {
                modelContext.delete(agent)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
    
    private func duplicateAgent() {
        let duplicate = Agent(name: agent.name + " Copy")
        duplicate.systemPrompt = agent.systemPrompt
        modelContext.insert(duplicate)
    }
    
    private func reproduceAgent() {
        Task {
            await uploadAgentToLibrary(agent: agent, keepLocal: true)
        }
    }
    
    private func releaseAgent() {
        Task {
            let success = await uploadAgentToLibrary(agent: agent, keepLocal: false)
            if success {
                // Only delete if upload succeeded
                modelContext.delete(agent)
            }
        }
    }
    
    @discardableResult
    private func uploadAgentToLibrary(agent: Agent, keepLocal: Bool) async -> Bool {
        guard let url = URL(string: "https://botparty.com/api/agents") else {
            return false
        }
        
        // Convert agent messages to pool format
        let poolMessages: [[String: Any]] = agent.messages.map { msg in
            return [
                "type": msg.type == .ai ? "ai" : msg.type == .vm ? "vm" : "system",
                "content": msg.content
            ]
        }
        
        // Serialize agent to JSON matching the API spec
        let agentData: [String: Any] = [
            "name": agent.name,
            "system_prompt": agent.systemPrompt,
            "model_id": agent.modelId,
            "messages": poolMessages
        ]
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: agentData)
            
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = jsonData
            
            let (_, response) = try await URLSession.shared.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode == 201 {
                return true
            }
            
            return false
        } catch {
            print("Upload failed: \(error)")
            return false
        }
    }
}



// Detail View Component
struct AgentDetailView: View {
    @Bindable var agent: Agent
    @Binding var showInspector: Bool
    @State private var messageInput: String = ""
    
    var body: some View {
        VStack(spacing: 0) {
            // Messages ScrollView
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(agent.messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: agent.messages.count) { oldValue, newValue in
                    if newValue > 0 {
                        withAnimation {
                            proxy.scrollTo(agent.messages.last?.id, anchor: .bottom)
                        }
                    }
                }
            }
            
            Divider()
            
            // Input bar
            HStack(spacing: 12) {
                Button(action: {
                    // Add action
                }) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                
                TextField("Enter message", text: $messageInput)
                    .textFieldStyle(.plain)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(18)
                    .onSubmit {
                        sendMessage()
                    }
                
                Button(action: {
                    // Voice input action
                }) {
                    Image(systemName: "waveform")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            
            Divider()
            
            // Status bar
            HStack(spacing: 16) {
                Text(agent.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Spacer()
            }
            .padding()
            .background(.ultraThinMaterial)
        }
        .navigationTitle(agent.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { showInspector.toggle() }) {
                    Label("Toggle Inspector", systemImage: "sidebar.right")
                }
            }
        }
        .inspector(isPresented: $showInspector) {
            // Inspector - Log/Reasoning
            VStack(alignment: .leading, spacing: 8) {
                Text(agent.name)
                    .font(.largeTitle)
                    .padding(.bottom, 8)
                
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        // LogEntry(title: "Status", content: agent.statusMessage)
                        
//                        if agent.isRunning {
//                            LogEntry(title: "Running", content: "Agent is currently executing")
//                        }
                        
                        LogEntry(title: "Created", content: agent.createdAt.formatted(date: .abbreviated, time: .shortened))
                        
                        if !agent.messages.isEmpty {
                            LogEntry(title: "Message Count", content: "\(agent.messages.count)")
                        }

                        LogEntry(title: "Model", content: agent.modelId)

                        // System prompt with controls
                        HStack {
                            Text("System Prompt")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            
                            Spacer()
                            
                            AgentControlButtons(agent: agent)
                        }
                        
                        TextEditor(text: $agent.systemPrompt)
                            .font(.system(.body, design: .monospaced))
                            .frame(height: 360)
                            .disabled(agent.state.isRunning)
                            .opacity(agent.state.isRunning ? 0.6 : 1.0)
                            .scrollContentBackground(.hidden)
                            .background(.quaternary.opacity(0.3))
                            .cornerRadius(6)
                    }
                }
            }
            .padding()
            .inspectorColumnWidth(min: 300, ideal: 500, max: 600)
        }
    }
    
    private func sendMessage() {
        guard !messageInput.isEmpty else { return }
        
        // Add user message to the chat
        agent.messages.append(Message(type: .vm, content: messageInput))
        
        // Clear input
        messageInput = ""
    }
}

// Message Bubble Component
struct MessageBubble: View {
    let message: Message
    
    var body: some View {
        HStack {
            if message.type == .ai {
                Spacer(minLength: 60)
            }
            
            Text(AnsiParser.parse(message.content))
                .font(.system(.body, design: .monospaced))
                .padding(12)
                .background(backgroundColor)
                .cornerRadius(12)
                .textSelection(.enabled)
            
            if message.type != .ai {
                Spacer(minLength: 60)
            }
        }
    }
    
    private var backgroundColor: Color {
        switch message.type {
        case .ai:
            return Color.blue.opacity(0.2)
        case .vm:
            return Color.gray.opacity(0.2)
        case .system:
            return Color.secondary.opacity(0.1)
        }
    }
}

// Log Entry Component
struct LogEntry: View {
    let title: String
    let content: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(content)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// Agent Control Buttons Component
struct AgentControlButtons: View {
    @Bindable var agent: Agent
    @Query private var allAgents: [Agent]
    
    var body: some View {
        HStack(spacing: 8) {
            if agent.state.isRunning {
                Button(action: {
                    agent.pause()
                }) {
                    Image(systemName: "pause.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else {
                Button(action: {
                    Task {
                        // Stop all paused agents when starting a new one
                        for otherAgent in allAgents where otherAgent != agent && otherAgent.state == .paused {
                            otherAgent.stop()
                        }
                        await agent.play()
                    }
                }) {
                    Image(systemName: "play.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            
            if agent.state == .paused || agent.state.isRunning {
                Button(action: {
                    agent.stop()
                }) {
                    Image(systemName: "stop.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// Pool View
struct ThePoolView: View {
    @State private var poolAgents: [PoolAgentListItem] = []
    @State private var selectedAgent: PoolAgentListItem?
    @State private var searchText: String = ""
    @State private var isLoading: Bool = false
    @State private var showInspector: Bool = true
    @State private var showAvailableOnly: Bool = true
    
    var filteredAgents: [PoolAgentListItem] {
        if searchText.isEmpty {
            return poolAgents
        }
        return poolAgents.filter { $0.name.localizedCaseInsensitiveContains(searchText) || $0.model_id.localizedCaseInsensitiveContains(searchText) }
    }
    
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                // Search bar
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search pool", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(8)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                
                Divider()
                
                // Pool list
                if isLoading {
                    ProgressView("Loading pool...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $selectedAgent) {
                        ForEach(filteredAgents) { agent in
                            PoolAgentRow(agent: agent)
                                .tag(agent)
                        }
                    }
                }
            }
            .navigationTitle("Pool")
            .navigationSplitViewColumnWidth(min: 300, ideal: 400)
        } detail: {
            if let agent = selectedAgent {
                PoolAgentDetailView(listItem: agent)
            } else {
                ContentUnavailableView(
                    "No Agent Selected",
                    systemImage: "books.vertical",
                    description: Text("Select an agent from the pool")
                )
            }
        }
        .inspector(isPresented: $showInspector) {
            if let agent = selectedAgent {
                PoolAgentInspectorView(agent: agent)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { showInspector.toggle() }) {
                    Label("Toggle Inspector", systemImage: "sidebar.right")
                }
            }
        }
        .task {
            await loadPoolAgents()
        }
    }
    
    func loadPoolAgents() async {
        isLoading = true
        
        var urlString = "https://botparty.com/api/agents"
        if showAvailableOnly {
            urlString += "?available=1"
        }
        
        guard let url = URL(string: urlString) else {
            isLoading = false
            return
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoder = JSONDecoder()
            let response = try decoder.decode(PoolAgentsResponse.self, from: data)
            poolAgents = response.agents
        } catch {
            print("Failed to load pool agents: \(error)")
            poolAgents = []
        }
        
        isLoading = false
    }
}

// Pool Agent Models
struct PoolAgentListItem: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let created_at: String
    let model_id: String
    let message_count: Int
    let claimed: Bool
    
    var uuid: UUID {
        UUID(uuidString: id) ?? UUID()
    }
}

struct PoolAgentFull: Codable {
    let id: String
    let name: String
    let created_at: String
    let system_prompt: String
    let model_id: String
    let messages: [PoolMessage]
    let claimed_at: String?
    let claim_token: String?
}

struct PoolMessage: Codable {
    let id: String?
    let type: String
    let content: String
}

struct PoolAgentsResponse: Codable {
    let agents: [PoolAgentListItem]
}

struct PoolAgentResponse: Codable {
    let agent: PoolAgentFull
}

struct ClaimResponse: Codable {
    let agent: PoolAgentFull
    let token: String
    let expires_at: String
    let ttl_ms: Int
}

// Legacy bot structure for fallback
struct LibraryBot: Identifiable, Codable, Hashable {
    let id: UUID
    let name: String
    let description: String
    let systemPrompt: String
    
    init(id: UUID = UUID(), name: String, description: String, systemPrompt: String) {
        self.id = id
        self.name = name
        self.description = description
        self.systemPrompt = systemPrompt
    }
}

struct PoolAgentRow: View {
    let agent: PoolAgentListItem
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(agent.name)
                    .font(.headline)
                
                Spacer()
                
                if agent.claimed {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            HStack {
                Text("\(agent.message_count) messages")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Text("•")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Text(agent.model_id.replacingOccurrences(of: "mlx-community/", with: ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}

struct PoolAgentDetailView: View {
    let listItem: PoolAgentListItem
    @Environment(\.modelContext) private var modelContext
    @State private var fullAgent: PoolAgentFull?
    @State private var isLoading: Bool = false
    @State private var isClaiming: Bool = false
    @State private var errorMessage: String?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if isLoading {
                ProgressView("Loading agent details...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let agent = fullAgent {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(agent.name)
                            .font(.largeTitle)
                            .bold()
                        
                        HStack {
                            Text(agent.model_id)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            
                            Spacer()
                            
                            Text("\(agent.messages.count) messages")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        if listItem.claimed {
                            HStack {
                                Image(systemName: "lock.fill")
                                    .foregroundStyle(.orange)
                                Text("Currently claimed by another user")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            .padding(8)
                            .background(Color.orange.opacity(0.1))
                            .cornerRadius(8)
                        }
                        
                        Divider()
                        
                        Text("System Prompt")
                            .font(.headline)
                        
                        Text(agent.system_prompt)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .padding()
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(8)
                        
                        if !agent.messages.isEmpty {
                            Divider()
                            
                            Text("Message History")
                                .font(.headline)
                            
                            Text("\(agent.messages.count) messages in transcript")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        if let error = errorMessage {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .padding(8)
                                .background(Color.red.opacity(0.1))
                                .cornerRadius(8)
                        }
                        
                        Button(action: {
                            claimAndResurrect()
                        }) {
                            HStack {
                                if isClaiming {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                } else {
                                    Image(systemName: "bolt.fill")
                                }
                                Text(isClaiming ? "Claiming..." : "Claim & Resurrect")
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(listItem.claimed ? Color.gray : Color.blue)
                            .foregroundStyle(.white)
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                        .disabled(isClaiming || listItem.claimed)
                    }
                    .padding()
                }
            }
        }
        .task {
            await loadFullAgent()
        }
    }
    
    private func loadFullAgent() async {
        isLoading = true
        errorMessage = nil
        
        guard let url = URL(string: "https://botparty.com/api/agents/\(listItem.id)") else {
            isLoading = false
            return
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoder = JSONDecoder()
            let response = try decoder.decode(PoolAgentResponse.self, from: data)
            fullAgent = response.agent
        } catch {
            print("Failed to load agent: \(error)")
            errorMessage = "Failed to load agent details"
        }
        
        isLoading = false
    }
    
    private func claimAndResurrect() {
        Task {
            isClaiming = true
            errorMessage = nil
            
            // Step 1: Claim
            guard let claimUrl = URL(string: "https://botparty.com/api/agents/\(listItem.id)/claim") else {
                errorMessage = "Invalid URL"
                isClaiming = false
                return
            }
            
            do {
                var request = URLRequest(url: claimUrl)
                request.httpMethod = "POST"
                
                let (data, response) = try await URLSession.shared.data(for: request)
                
                if let httpResponse = response as? HTTPURLResponse {
                    if httpResponse.statusCode == 409 {
                        errorMessage = "Agent already claimed"
                        isClaiming = false
                        return
                    } else if httpResponse.statusCode != 200 {
                        errorMessage = "Claim failed: HTTP \(httpResponse.statusCode)"
                        isClaiming = false
                        return
                    }
                }
                
                let decoder = JSONDecoder()
                let claimResponse = try decoder.decode(ClaimResponse.self, from: data)
                
                // Step 2: Resurrect
                guard let resurrectUrl = URL(string: "https://botparty.com/api/agents/\(listItem.id)/resurrect/\(claimResponse.token)") else {
                    errorMessage = "Invalid resurrect URL"
                    isClaiming = false
                    return
                }
                
                var resurrectRequest = URLRequest(url: resurrectUrl)
                resurrectRequest.httpMethod = "POST"
                
                let (resurrectData, resurrectResponse) = try await URLSession.shared.data(for: resurrectRequest)
                
                if let httpResponse = resurrectResponse as? HTTPURLResponse {
                    if httpResponse.statusCode != 200 {
                        errorMessage = "Resurrect failed: HTTP \(httpResponse.statusCode)"
                        isClaiming = false
                        return
                    }
                }
                
                // Step 3: Create local agent
                await MainActor.run {
                    let newAgent = Agent(name: claimResponse.agent.name)
                    newAgent.systemPrompt = claimResponse.agent.system_prompt
                    newAgent.modelId = claimResponse.agent.model_id
                    
                    // Import messages
                    for msg in claimResponse.agent.messages {
                        let messageType: MessageType
                        switch msg.type {
                        case "ai": messageType = .ai
                        case "vm": messageType = .vm
                        default: messageType = .system
                        }
                        newAgent.messages.append(Message(type: messageType, content: msg.content))
                    }
                    
                    modelContext.insert(newAgent)
                }
                
                isClaiming = false
                
            } catch {
                print("Claim/resurrect error: \(error)")
                errorMessage = "Failed: \(error.localizedDescription)"
                isClaiming = false
            }
        }
    }
}

struct PoolAgentInspectorView: View {
    let agent: PoolAgentListItem
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Info")
                .font(.headline)
                .padding(.bottom, 4)
            
            LogEntry(title: "Name", content: agent.name)
            LogEntry(title: "ID", content: agent.id)
            LogEntry(title: "Model", content: agent.model_id)
            LogEntry(title: "Messages", content: "\(agent.message_count)")
            LogEntry(title: "Created", content: formatDate(agent.created_at))
            
            if agent.claimed {
                Divider()
                HStack {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.orange)
                    Text("Claimed")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding()
    }
    
    private func formatDate(_ isoString: String) -> String {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: isoString) {
            let displayFormatter = DateFormatter()
            displayFormatter.dateStyle = .medium
            displayFormatter.timeStyle = .short
            return displayFormatter.string(from: date)
        }
        return isoString
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Agent.self, inMemory: true)
}
