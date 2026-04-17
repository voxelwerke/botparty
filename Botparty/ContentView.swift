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
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if isEditingName {
                    TextField("Agent name", text: $agent.name, onCommit: {
                        isEditingName = false
                    })
                    .font(.headline)
                    .textFieldStyle(.plain)
                } else {
                    Text(agent.name)
                        .font(.headline)
                }
                
                Spacer()
                
                Button(action: {
                    if agent.isRunning {
                        agent.pause()
                    } else {
                        Task {
                            await agent.play()
                        }
                    }
                }) {
                    Image(systemName: agent.isRunning ? "pause.fill" : "play.fill")
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
        .contextMenu {
            Button {
                isEditingName = true
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            
            Button(role: .destructive) {
                modelContext.delete(agent)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

import SwiftUI

class AnsiParser {
    static func parse(_ input: String) -> AttributedString {
        var container = AttributeContainer()
        var result = AttributedString()
        
        // Split by the Escape character
        let components = input.components(separatedBy: "\u{1b}[")
        
        for (index, component) in components.enumerated() {
            if index == 0 {
                // The first part is just plain text before any escape codes
                result += AttributedString(component)
                continue
            }
            
            // Look for the 'm' that ends the escape sequence
            if let mIndex = component.firstIndex(of: "m") {
                let code = component[..<mIndex]
                let remainingText = component[component.index(after: mIndex)...]
                
                // Update our state based on the code
                updateAttributes(&container, for: String(code))
                
                // Add the text with the current state applied
                var coloredSegment = AttributedString(String(remainingText))
                coloredSegment.mergeAttributes(container)
                result += coloredSegment
            } else {
                // If no 'm' found, it wasn't a formatting code, just print it
                result += AttributedString(component)
            }
        }
        return result
    }
    
    private static func updateAttributes(_ container: inout AttributeContainer, for code: String) {
        switch code {
        case "0": // Reset
            container = AttributeContainer()
        case "1": // Bold
            container.font = .system(.body, design: .monospaced).bold()
        case "31", "1;31": // Red
            container.foregroundColor = .red
        case "32", "1;32": // Green
            container.foregroundColor = .green
        case "33", "1;33": // Yellow
            container.foregroundColor = .yellow
        case "34", "1;34": // Blue
            container.foregroundColor = .blue
        case "35", "1;35": // Magenta
            container.foregroundColor = .pink // Monokai vibes
        case "36", "1;36": // Cyan
            container.foregroundColor = .cyan
        default:
            break // Ignore codes we don't care about (like cursor movement)
        }
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
                        ForEach(Array(agent.responses.enumerated()), id: \.offset) { index, response in
                            MessageBubble(text: response)
                                .id(index)
                        }
                    }
                    .padding()
                }
                .onChange(of: agent.responses.count) { oldValue, newValue in
                    if newValue > 0 {
                        withAnimation {
                            proxy.scrollTo(newValue - 1, anchor: .bottom)
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
                Text("Log & Reasoning")
                    .font(.headline)
                    .padding(.bottom, 4)
                
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        LogEntry(title: "Status", content: agent.statusMessage)
                        
                        if agent.isRunning {
                            LogEntry(title: "Running", content: "Agent is currently executing")
                        }
                        
                        LogEntry(title: "Created", content: agent.createdAt.formatted(date: .abbreviated, time: .shortened))
                        
                        if !agent.responses.isEmpty {
                            LogEntry(title: "Response Count", content: "\(agent.responses.count)")
                        }

                        // System promopt
                        Text("System Prompt")
                            .font(.caption)
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
    let text: String
    
    var body: some View {
        Text(AnsiParser.parse(text))
            .font(.system(.body, design: .monospaced))
            .padding(12)
            .background(.regularMaterial)
            .cornerRadius(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
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
