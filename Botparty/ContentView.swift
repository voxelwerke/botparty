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
                
                Button(action: {
                    if agent.isRunning {
                        Task {
                            await agent.stop()
                        }
                    } else {
                        Task {
                            await agent.play()
                        }
                    }
                }) {
                    Image(systemName: agent.isRunning ? "stop.fill" : "play.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
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
                    .font(.headline)
                    .padding(.bottom, 4)
                
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

                        // System promopt
                        Text("System Prompt")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        
                        TextEditor(text: $agent.systemPrompt)
                            .font(.system(.body, design: .monospaced))
                            .frame(height: 360)
                            .disabled(agent.isRunning)
                            .opacity(agent.isRunning ? 0.6 : 1.0)
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

#Preview {
    ContentView()
        .modelContainer(for: Agent.self, inMemory: true)
}
