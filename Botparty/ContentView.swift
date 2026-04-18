//
//  ContentView.swift
//  Botparty
//
//  Created by Ben Nolan on 16/04/2026.
//

import SwiftUI
import SwiftData


struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Agent.createdAt, order: .reverse) private var agents: [Agent]
    @State private var selectedAgent: Agent?
    @State private var showInspector: Bool = true
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // Sidebar - Agents List
            List(selection: $selectedAgent) {
                ForEach(agents) { agent in
                    AgentSidebarRow(agent: agent)
                        .tag(agent)
                        .listRowBackground(
                            selectedAgent == agent ? Color.gray.opacity(0.2) : Color.clear
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
            // Detail View - Chat Area
            if let agent = selectedAgent {
                AgentDetailView(agent: agent, showInspector: $showInspector)
            } else {
                ContentUnavailableView(
                    "No Agent Selected",
                    systemImage: "robot",
                    description: Text("Select an agent from the sidebar or create a new one")
                )
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
    
    private func createNewAgent() {
        let newAgent = Agent()
        modelContext.insert(newAgent)
        selectedAgent = newAgent
        
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
        if selectedAgent == agent {
            selectedAgent = nil
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
            
            Button {
                duplicateAgent()
            } label: {
                Label("Duplicate", systemImage: "doc.on.doc")
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

#Preview {
    ContentView()
        .modelContainer(for: Agent.self, inMemory: true)
}
