//
//  ClaudeCodeQuotaFetcher.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//
//  Fetches quota from Claude Code API using stored OAuth credentials
//  Uses direct API call to https://api.anthropic.com/api/oauth/usage
//

import Foundation

// MARK: - API Response Models

/// Response from Claude Code usage API
private struct ClaudeUsageResponse: Codable, Sendable {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    let sevenDayOauthApps: UsageWindow?
    let sevenDayOpus: UsageWindow?
    let sevenDaySonnet: UsageWindow?
    let iguanaNecktie: UsageWindow?
    let extraUsage: ExtraUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOauthApps = "seven_day_oauth_apps"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case iguanaNecktie = "iguana_necktie"
        case extraUsage = "extra_usage"
    }

    struct UsageWindow: Codable, Sendable {
        let utilization: Double?
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }

    struct ExtraUsage: Codable, Sendable {
        let isEnabled: Bool?
        let monthlyLimit: Int?
        let usedCredits: Double?
        let utilization: Double?

        enum CodingKeys: String, CodingKey {
            case isEnabled = "is_enabled"
            case monthlyLimit = "monthly_limit"
            case usedCredits = "used_credits"
            case utilization
        }
    }
}

/// Auth file structure for Claude credentials
private struct ClaudeAuthFile: Codable, Sendable {
    let accessToken: String
    let email: String?
    let expired: String?
    let idToken: String?
    let lastRefresh: String?
    let refreshToken: String?
    let type: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case email
        case expired
        case idToken = "id_token"
        case lastRefresh = "last_refresh"
        case refreshToken = "refresh_token"
        case type
    }

    var isExpired: Bool {
        guard let expired = expired else { return true }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withColonSeparatorInTimeZone]

        if let expiryDate = formatter.date(from: expired) {
            return Date() > expiryDate
        }

        // Try without fractional seconds
        formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        if let expiryDate = formatter.date(from: expired) {
            return Date() > expiryDate
        }

        return true
    }
}

// MARK: - Fetcher

/// Fetches quota from Claude Code API
actor ClaudeCodeQuotaFetcher {
    private let usageAPIURL = "https://api.anthropic.com/api/oauth/usage"
    private let tokenRefreshURL = "https://api.anthropic.com/api/oauth/token"
    private let userAgent = "claude-code/2.0.76"
    private let oauthBeta = "oauth-2025-04-20"

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)
    }

    /// Fetch quota using access token
    func fetchQuota(accessToken: String) async throws -> ProviderQuotaData {
        var request = URLRequest(url: URL(string: usageAPIURL)!)
        request.httpMethod = "GET"
        request.addValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.addValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue(oauthBeta, forHTTPHeaderField: "anthropic-beta")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeQuotaError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            throw ClaudeQuotaError.unauthorized
        }

        if httpResponse.statusCode == 403 {
            return ProviderQuotaData(isForbidden: true)
        }

        guard 200...299 ~= httpResponse.statusCode else {
            throw ClaudeQuotaError.httpError(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        let usageResponse = try decoder.decode(ClaudeUsageResponse.self, from: data)

        var models: [ModelQuota] = []

        // 5-hour usage window
        if let fiveHour = usageResponse.fiveHour {
            let utilization = fiveHour.utilization ?? 0
            let remaining = 100 - utilization
            let resetTime = fiveHour.resetsAt ?? ""

            models.append(ModelQuota(
                name: "5-hour",
                percentage: remaining,
                resetTime: resetTime
            ))
        }

        // 7-day usage window
        if let sevenDay = usageResponse.sevenDay {
            let utilization = sevenDay.utilization ?? 0
            let remaining = 100 - utilization
            let resetTime = sevenDay.resetsAt ?? ""

            models.append(ModelQuota(
                name: "weekly",
                percentage: remaining,
                resetTime: resetTime
            ))
        }

        // Opus-specific limit (if present)
        if let opus = usageResponse.sevenDayOpus {
            let utilization = opus.utilization ?? 0
            let remaining = 100 - utilization
            let resetTime = opus.resetsAt ?? ""

            models.append(ModelQuota(
                name: "opus-weekly",
                percentage: remaining,
                resetTime: resetTime
            ))
        }

        // Sonnet-specific limit (if present)
        if let sonnet = usageResponse.sevenDaySonnet {
            let utilization = sonnet.utilization ?? 0
            let remaining = 100 - utilization
            let resetTime = sonnet.resetsAt ?? ""

            models.append(ModelQuota(
                name: "sonnet-weekly",
                percentage: remaining,
                resetTime: resetTime
            ))
        }

        return ProviderQuotaData(models: models, lastUpdated: Date())
    }

    /// Fetch quota from auth file at given path
    func fetchQuotaForAuthFile(at path: String) async throws -> ProviderQuotaData {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        let authFile = try JSONDecoder().decode(ClaudeAuthFile.self, from: data)

        // TODO: Implement token refresh if expired
        // For now, just use the existing token
        let accessToken = authFile.accessToken

        return try await fetchQuota(accessToken: accessToken)
    }

    /// Fetch all Claude Code quotas from ~/.cli-proxy-api
    func fetchAllClaudeQuotas(authDir: String = "~/.cli-proxy-api") async -> [String: ProviderQuotaData] {
        let expandedPath = NSString(string: authDir).expandingTildeInPath
        let fileManager = FileManager.default

        guard let files = try? fileManager.contentsOfDirectory(atPath: expandedPath) else {
            return [:]
        }

        var results: [String: ProviderQuotaData] = [:]
        let claudeFiles = files.filter { $0.hasPrefix("claude-") && $0.hasSuffix(".json") }

        for file in claudeFiles {
            let filePath = (expandedPath as NSString).appendingPathComponent(file)

            do {
                let quota = try await fetchQuotaForAuthFile(at: filePath)
                let email = file
                    .replacingOccurrences(of: "claude-", with: "")
                    .replacingOccurrences(of: ".json", with: "")
                results[email] = quota
            } catch {
                // Silently skip failed auth files
            }
        }

        return results
    }

    /// Convert to ProviderQuotaData for unified display
    func fetchAsProviderQuota() async -> [String: ProviderQuotaData] {
        return await fetchAllClaudeQuotas()
    }
}

// MARK: - Errors

enum ClaudeQuotaError: LocalizedError {
    case invalidURL
    case invalidResponse
    case unauthorized
    case forbidden
    case httpError(Int)
    case tokenRefreshFailed
    case noAuthFiles

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .invalidResponse: return "Invalid response from server"
        case .unauthorized: return "Unauthorized - token may be expired"
        case .forbidden: return "Access forbidden"
        case .httpError(let code): return "HTTP error: \(code)"
        case .tokenRefreshFailed: return "Failed to refresh token"
        case .noAuthFiles: return "No Claude auth files found"
        }
    }
}
