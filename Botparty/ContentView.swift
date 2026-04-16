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
    
    var body: some View {
        NavigationSplitView {
            // Sidebar - Agents List
            List(selection: $selectedAgent) {
                ForEach(agents) { agent in
                    AgentSidebarRow(agent: agent)
                        .tag(agent)
                        .contextMenu {
                            Button(role: .destructive) {
                                deleteAgent(agent)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
            }
            .navigationTitle("Agents")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: createNewAgent) {
                        Label("Add Agent", systemImage: "plus")
                    }
                }
            }
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
        .background(
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(red: 0xCB / 255, green: 0x43 / 255, blue: 0xF6 / 255),
                    Color(red: 0xEC / 255, green: 0x4C / 255, blue: 0xBD / 255)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
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
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(agent.name)
                .font(.headline)
            
            HStack {
                Text(agent.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                
                Spacer()
                
                if agent.isRunning {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            
            if agent.isRunning && agent.loadingProgress > 0 {
                ProgressView(value: agent.loadingProgress, total: 1.0)
                    .progressViewStyle(.linear)
            }
        }
        .padding(.vertical, 4)
    }
}

// Detail View Component
struct AgentDetailView: View {
    @Bindable var agent: Agent
    @Binding var showInspector: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            // Messages area
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(agent.responses.indices, id: \.self) { index in
                        MessageBubble(text: agent.responses[index])
                    }
                }
                .padding()
            }
            
            Divider()
            
            // Control bar
            HStack(spacing: 16) {
                HStack(spacing: 12) {
                    Button(action: {
                        Task {
                            await agent.play()
                        }
                    }) {
                        Label("Play", systemImage: "play.fill")
                            .labelStyle(.iconOnly)
                    }
                    .disabled(agent.isRunning)
                    
                    Button(action: {
                        agent.pause()
                    }) {
                        Label("Pause", systemImage: "pause.fill")
                            .labelStyle(.iconOnly)
                    }
                    .disabled(!agent.isRunning)
                }
                
                Spacer()
                
                if agent.isRunning && agent.loadingProgress > 0 {
                    Text("\(Int(agent.loadingProgress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Text(agent.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                Text("Log & Reasoning")
                    .font(.headline)
                    .padding(.bottom, 4)
                
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        LogEntry(title: "Status", content: agent.statusMessage)
                        
                        if agent.isRunning {
                            LogEntry(title: "Running", content: "Agent is currently executing")
                        }
                        
                        if agent.loadingProgress > 0 {
                            LogEntry(title: "Progress", content: "\(Int(agent.loadingProgress * 100))%")
                        }
                        
                        LogEntry(title: "Created", content: agent.createdAt.formatted(date: .abbreviated, time: .shortened))
                        
                        if !agent.responses.isEmpty {
                            LogEntry(title: "Response Count", content: "\(agent.responses.count)")
                        }
                    }
                }
            }
            .padding()
            .inspectorColumnWidth(min: 200, ideal: 250, max: 400)
        }
    }
}

// Message Bubble Component
struct MessageBubble: View {
    let text: String
    
    var body: some View {
        Text(text)
            .padding(12)
            .background(.regularMaterial)
            .cornerRadius(12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// Log Entry Component
struct LogEntry: View {
    let title: String
    let content: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(content)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3))
        .cornerRadius(6)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Agent.self, inMemory: true)
}
