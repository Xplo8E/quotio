//
//  AgentSetupViewModel.swift
//  Quotio - Agent Setup State Management
//

import Foundation
import SwiftUI
import AppKit

@MainActor
@Observable
final class AgentSetupViewModel {
    private let detectionService = AgentDetectionService()
    private let configurationService = AgentConfigurationService()
    private let shellManager = ShellProfileManager()
    
    var agentStatuses: [AgentStatus] = []
    var isLoading = false
    var isConfiguring = false
    var isTesting = false
    var selectedAgent: CLIAgent?
    var configResult: AgentConfigResult?
    var testResult: ConnectionTestResult?
    var errorMessage: String?
    var availableModels: [AvailableModel] = []
    var isLoadingModels = false
    
    var currentConfiguration: AgentConfiguration?
    var detectedShell: ShellType = .zsh
    var configurationMode: ConfigurationMode = .automatic
    var configStorageOption: ConfigStorageOption = .jsonOnly
    var selectedRawConfigIndex: Int = 0
    
    weak var proxyManager: CLIProxyManager?
    
    init() {}
    
    func setup(proxyManager: CLIProxyManager) {
        self.proxyManager = proxyManager
    }
    
    func refreshAgentStatuses(forceRefresh: Bool = false) async {
        isLoading = true
        defer { isLoading = false }
        
        agentStatuses = await detectionService.detectAllAgents(forceRefresh: forceRefresh)
        detectedShell = await shellManager.detectShell()
    }
    
    func status(for agent: CLIAgent) -> AgentStatus? {
        agentStatuses.first { $0.agent == agent }
    }
    
    func startConfiguration(for agent: CLIAgent, apiKey: String) {
        configResult = nil
        testResult = nil
        selectedRawConfigIndex = 0
        configurationMode = .automatic
        configStorageOption = .jsonOnly
        isConfiguring = false
        isTesting = false
        availableModels = []
        
        guard let proxyManager = proxyManager else {
            errorMessage = "Proxy manager not available"
            return
        }
        
        selectedAgent = agent
        currentConfiguration = AgentConfiguration(
            agent: agent,
            proxyURL: proxyManager.baseURL + "/v1",
            apiKey: apiKey
        )
        
        // Fetch available models from proxy
        Task {
            await fetchAvailableModels()
        }
    }
    
    func fetchAvailableModels() async {
        guard let config = currentConfiguration else { return }
        
        isLoadingModels = true
        defer { isLoadingModels = false }
        
        availableModels = await configurationService.fetchAvailableModels(
            proxyURL: config.proxyURL,
            apiKey: config.apiKey
        )
        
        // If we got models and current slots are defaults, intelligently assign models
        if !availableModels.isEmpty, let config = currentConfiguration {
            // Only update if using default/placeholder models
            if config.modelSlots[.opus] == AvailableModel.defaultModels[.opus]?.name {
                // Find best matching model for each slot
                let opusModel = findBestModel(for: .opus, in: availableModels)
                let sonnetModel = findBestModel(for: .sonnet, in: availableModels)
                let haikuModel = findBestModel(for: .haiku, in: availableModels)
                
                currentConfiguration?.modelSlots[.opus] = opusModel
                currentConfiguration?.modelSlots[.sonnet] = sonnetModel
                currentConfiguration?.modelSlots[.haiku] = haikuModel
            }
        }
    }
    
    /// Find best matching model for a given slot based on naming patterns
    private func findBestModel(for slot: ModelSlot, in models: [AvailableModel]) -> String {
        let modelNames = models.map { $0.name.lowercased() }
        let defaultModel = models.first?.name ?? ""
        
        switch slot {
        case .opus:
            // Prefer opus, then sonnet, then first available
            if let match = models.first(where: { $0.name.lowercased().contains("opus") }) {
                return match.name
            }
            if let match = models.first(where: { $0.name.lowercased().contains("sonnet") }) {
                return match.name
            }
            return defaultModel
            
        case .sonnet:
            // Prefer sonnet, then first available
            if let match = models.first(where: { $0.name.lowercased().contains("sonnet") }) {
                return match.name
            }
            return defaultModel
            
        case .haiku:
            // Prefer haiku, flash, or fast models
            if let match = models.first(where: { $0.name.lowercased().contains("haiku") }) {
                return match.name
            }
            if let match = models.first(where: { $0.name.lowercased().contains("flash") }) {
                return match.name
            }
            return defaultModel
        }
    }
    
    func updateModelSlot(_ slot: ModelSlot, model: String) {
        currentConfiguration?.modelSlots[slot] = model
    }
    
    func applyConfiguration() async {
        guard let agent = selectedAgent,
              let config = currentConfiguration else { return }
        
        isConfiguring = true
        defer { isConfiguring = false }
        
        do {
            var result = try await configurationService.generateConfiguration(
                agent: agent,
                config: config,
                mode: configurationMode,
                storageOption: agent == .claudeCode ? configStorageOption : .jsonOnly,
                detectionService: detectionService
            )
            
            if configurationMode == .automatic && result.success {
                let shouldUpdateShell = agent.configType == .both
                    ? (configStorageOption == .shellOnly || configStorageOption == .both)
                    : agent.configType != .file
                
                if let shellConfig = result.shellConfig, shouldUpdateShell {
                    try await shellManager.addToProfile(
                        shell: detectedShell,
                        configuration: shellConfig,
                        agent: agent
                    )
                }
                
                await detectionService.markAsConfigured(agent)
                await refreshAgentStatuses()
            }
            
            configResult = result
            
            if !result.success {
                errorMessage = result.error
            }
        } catch {
            errorMessage = error.localizedDescription
            configResult = .failure(error: error.localizedDescription)
        }
    }
    
    func addToShellProfile() async {
        guard let agent = selectedAgent,
              let shellConfig = configResult?.shellConfig else { return }
        
        do {
            try await shellManager.addToProfile(
                shell: detectedShell,
                configuration: shellConfig,
                agent: agent
            )
            
            configResult = AgentConfigResult.success(
                type: configResult?.configType ?? .environment,
                mode: configurationMode,
                configPath: configResult?.configPath,
                authPath: configResult?.authPath,
                shellConfig: shellConfig,
                rawConfigs: configResult?.rawConfigs ?? [],
                instructions: "Added to \(detectedShell.profilePath). Restart your terminal for changes to take effect.",
                modelsConfigured: configResult?.modelsConfigured ?? 0
            )
            
            await detectionService.markAsConfigured(agent)
            await refreshAgentStatuses()
        } catch {
            errorMessage = "Failed to update shell profile: \(error.localizedDescription)"
        }
    }
    
    func copyToClipboard() {
        guard let shellConfig = configResult?.shellConfig else { return }
        
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(shellConfig, forType: .string)
    }
    
    func copyRawConfigToClipboard(index: Int) {
        guard let result = configResult,
              index < result.rawConfigs.count else { return }
        
        let rawConfig = result.rawConfigs[index]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rawConfig.content, forType: .string)
    }
    
    func copyAllRawConfigsToClipboard() {
        guard let result = configResult else { return }
        
        let allContent = result.rawConfigs.map { config in
            """
            # \(config.filename ?? "Configuration")
            # Target: \(config.targetPath ?? "N/A")
            
            \(config.content)
            """
        }.joined(separator: "\n\n---\n\n")
        
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(allContent, forType: .string)
    }
    
    func testConnection() async {
        guard let agent = selectedAgent,
              let config = currentConfiguration else { return }
        
        isTesting = true
        defer { isTesting = false }
        
        testResult = await configurationService.testConnection(
            agent: agent,
            config: config
        )
    }
    
    func generatePreviewConfig() async -> AgentConfigResult? {
        guard let agent = selectedAgent,
              let config = currentConfiguration else { return nil }
        
        do {
            return try await configurationService.generateConfiguration(
                agent: agent,
                config: config,
                mode: .manual,
                detectionService: detectionService
            )
        } catch {
            return nil
        }
    }
    
    func dismissConfiguration() {
        selectedAgent = nil
        configResult = nil
        testResult = nil
        currentConfiguration = nil
        errorMessage = nil
        selectedRawConfigIndex = 0
        isConfiguring = false
        isTesting = false
    }
    
    func resetSheetState() {
        configResult = nil
        testResult = nil
        selectedRawConfigIndex = 0
        configurationMode = .automatic
        configStorageOption = .jsonOnly
        isConfiguring = false
        isTesting = false
    }
}
