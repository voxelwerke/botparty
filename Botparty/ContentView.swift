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

    var body: some View {
        VStack(spacing: 0) {
            // Agents list
            List {
                ForEach(agents) { agent in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(agent.name)
                                .font(.headline)
                            Text(agent.statusMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            
                            if agent.isRunning && agent.loadingProgress > 0 {
                                ProgressView(value: agent.loadingProgress, total: 1.0)
                                    .progressViewStyle(.linear)
                            }
                            
                            // Display responses
                            if !agent.responses.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(agent.responses.indices, id: \.self) { index in
                                        Text(agent.responses[index])
                                            .font(.caption)
                                            .padding(.vertical, 2)
                                    }
                                }
                                .padding(.top, 4)
                            }
                        }
                        
                        Spacer()
                        
                        HStack(spacing: 12) {
                            Button(action: {
                                Task {
                                    await agent.play()
                                }
                            }) {
                                Image(systemName: "play.fill")
                                    .foregroundStyle(agent.isRunning ? .secondary : .primary)
                            }
                            .disabled(agent.isRunning)
                            
                            Button(action: {
                                agent.pause()
                            }) {
                                Image(systemName: "pause.fill")
                                    .foregroundStyle(agent.isRunning ? .primary : .secondary)
                            }
                            .disabled(!agent.isRunning)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            
            // Create new agent button
            Button(action: {
                let newAgent = Agent()
                modelContext.insert(newAgent)
            }) {
                HStack {
                    Image(systemName: "plus.circle.fill")
                    Text("Create New Agent")
                }
                .frame(maxWidth: .infinity)
                .padding()
            }
            .background(.ultraThinMaterial)
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
        )
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Agent.self, inMemory: true)
}
