import Foundation
import SwiftUI
import NetworkExtension

// 添加 LogManager
private let logger = LogManager.shared

// 将 VersionResponse 移到类外面
struct VersionResponse: Codable {
    let meta: Bool?
    let premium: Bool?
    let version: String
}

// 添加一个结构体来表示启动状态
public struct StartLogResponse: Codable {
    let startlog: String
}

struct ClashStatusResponse: Codable {
    let id: Int?
    let result: String
    let error: String?
}

// 添加 ListResponse 结构体
struct ListResponse: Codable {
    let id: Int?
    let result: String
    let error: String?
}

// 添加文件系统 RPC 响应的结构体
struct FSGlobResponse: Codable {
    let id: Int?
    let result: ([String], Int)  // [文件路径数组, 文件数量]
    let error: String?
    
    enum CodingKeys: String, CodingKey {
        case id
        case result
        case error
    }
    
    // 自定义解码方法来处理元组类型
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        
        // 解码 result 数组
        var resultContainer = try container.nestedUnkeyedContainer(forKey: .result)
        let fileList = try resultContainer.decode([String].self)
        let count = try resultContainer.decode(Int.self)
        result = (fileList, count)
    }
    
    // 自定义编码方法
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(error, forKey: .error)
        
        // 编码 result 元组
        var resultContainer = container.nestedUnkeyedContainer(forKey: .result)
        try resultContainer.encode(result.0)  // 文件列表
        try resultContainer.encode(result.1)  // 文件数量
    }
}

struct FSStatResponse: Codable {
    let id: Int?
    let result: FSStatResult
    let error: String?
}

struct FSStatResult: Codable {
    let type: String
    let mtime: Int
    let size: Int
    let modestr: String
}

struct ServerCheckSummary {
    let name: String
    let address: String
    let success: Bool
    let typeText: String
    let codeText: String
    let detailText: String
    let durationSeconds: Double
}

@MainActor
class ServerViewModel: NSObject, ObservableObject, URLSessionDelegate, URLSessionTaskDelegate {
    @Published private(set) var servers: [ClashServer] = []
    @Published var showError = false
    @Published var errorMessage: String?
    @Published var errorDetails: String?
    @Published private(set) var hideDisconnectedServers: Bool
    
    private let defaults = UserDefaults.standard
    private let logger = LogManager.shared
    private weak var bindingManager: WiFiBindingManager?
    private var currentWiFiSSID: String?
    
    private static let saveKey = "SavedClashServers"
    private var activeSessions: [URLSession] = []  // 保持 URLSession 的引用
    
    init(bindingManager: WiFiBindingManager? = nil) {
        self.hideDisconnectedServers = UserDefaults.standard.bool(forKey: "hideDisconnectedServers")
        self.bindingManager = bindingManager
        super.init()
        loadServers()
        
        // 监听 hideDisconnectedServers 的变化
        NotificationCenter.default.addObserver(self, selector: #selector(userDefaultsDidChange), name: UserDefaults.didChangeNotification, object: nil)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc private func userDefaultsDidChange() {
        let newValue = UserDefaults.standard.bool(forKey: "hideDisconnectedServers")
        if newValue != hideDisconnectedServers {
            DispatchQueue.main.async { [weak self] in
                self?.hideDisconnectedServers = newValue
            }
        }
    }
    
    func setBingingManager(_ manager: WiFiBindingManager) {
        self.bindingManager = manager
    }
    
    // 描述一组服务器ID为可读字符串
    private func describeServers(by ids: [String]) -> String {
        if ids.isEmpty { return "无" }
        let idSet = Set(ids)
        let matched = servers.filter { idSet.contains($0.id.uuidString) }
        if matched.isEmpty { return ids.joined(separator: ", ") }
        return matched.map { server in
            let address: String
            if server.source == .clashController {
                address = "\(server.url):\(server.port)"
            } else {
                let host = server.openWRTUrl ?? server.url
                let port = server.openWRTPort ?? server.port
                address = "\(host):\(port)"
            }
            return "\(server.displayName)[\(address)]"
        }.joined(separator: ", ")
    }
    
    // 输出一次 Wi‑Fi 绑定概要日志，避免刷屏
    func logWiFiBindingSummary(currentWiFiSSID: String) {
        let enabled = UserDefaults.standard.bool(forKey: "enableWiFiBinding")
        logger.info("[WiFi绑定] 功能: \(enabled ? "已启用" : "未启用")")
        guard enabled else { return }
        
        let cachedSSID = UserDefaults.standard.string(forKey: "current_ssid") ?? ""
        let rawSSID = currentWiFiSSID.isEmpty ? cachedSSID : currentWiFiSSID
        let ssid = rawSSID.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if ssid.isEmpty {
            logger.info("[WiFi绑定] Wi‑Fi: 未连接")
            // 未连接时展示默认控制器
            let defaultsIds: Set<String> = bindingManager?.defaultServerIds ?? loadDefaultServerIdsFromDefaults()
            logger.info("[WiFi绑定] 绑定控制器: \(describeServers(by: Array(defaultsIds)))")
            return
        }
        
        logger.info("[WiFi绑定] Wi‑Fi: 已连接（\(ssid)）")
        let bindingsSource: [WiFiBinding] = bindingManager?.bindings ?? loadBindingsFromDefaults()
        if let binding = bindingsSource.first(where: { $0.ssid == ssid })
            ?? bindingsSource.first(where: { $0.ssid.trimmingCharacters(in: .whitespacesAndNewlines) == ssid })
            ?? bindingsSource.first(where: { $0.ssid.lowercased() == ssid.lowercased() }) {
            logger.info("[WiFi绑定] 绑定控制器: \(describeServers(by: binding.serverIds))")
        } else {
            // 未找到绑定时展示默认控制器
            let defaultsIds: Set<String> = bindingManager?.defaultServerIds ?? loadDefaultServerIdsFromDefaults()
            logger.info("绑定控制器: \(describeServers(by: Array(defaultsIds)))")
        }
    }
    
    // 从 UserDefaults 加载 Wi-Fi 绑定（当 bindingManager 尚未注入时作为回退）
    private func loadBindingsFromDefaults() -> [WiFiBinding] {
        if let data = UserDefaults.standard.data(forKey: "wifi_bindings"),
           let bindings = try? JSONDecoder().decode([WiFiBinding].self, from: data) {
            return bindings
        }
        return []
    }
    
    // 从 UserDefaults 加载默认控制器 ID 列表（当 bindingManager 尚未注入时作为回退）
    private func loadDefaultServerIdsFromDefaults() -> Set<String> {
        if let array = UserDefaults.standard.stringArray(forKey: "default_servers") {
            return Set(array)
        }
        return []
    }
    
    private func determineServerType(from response: VersionResponse) -> ClashServer.ServerType {
        // 检查是否是 sing-box
        if response.version.lowercased().contains("sing") {
            // logger.log("检测到后端为 sing-box 内核")
            return .singbox
        }
        
        // 如果不是 sing-box，则按原有逻辑判断
        if response.meta == true {
            // logger.log("检测到后端为 Meta 内核")
            return .meta
        }
        // logger.log("检测到后端为 Premium （原版 Clash）内核")
        return .premium
    }
    
    private func makeURLSession(for server: ClashServer) -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 30

        // 根据服务器类型检查是否启用 SSL
        let useSSL: Bool
        switch server.source {
        case .clashController:
            useSSL = server.clashUseSSL
        case .openWRT:
            useSSL = server.openWRTUseSSL
        case .surge:
            useSSL = server.surgeUseSSL
        }

        if useSSL {
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            if #available(iOS 15.0, *) {
                config.tlsMinimumSupportedProtocolVersion = .TLSv12
            } else {
                config.tlsMinimumSupportedProtocolVersion = .TLSv12
            }
            config.tlsMaximumSupportedProtocolVersion = .TLSv13
        }

        let session = URLSessionManager.shared.makeCustomSession()
        activeSessions.append(session)  // 保存 session 引用
        return session
    }
    
    private func makeRequest(for server: ClashServer, path: String) -> URLRequest? {
        // 根据服务器类型选择正确的 SSL 设置
        let useSSL: Bool
        switch server.source {
        case .clashController:
            useSSL = server.clashUseSSL
        case .openWRT:
            useSSL = server.openWRTUseSSL
        case .surge:
            useSSL = server.surgeUseSSL
        }

        let scheme = useSSL ? "https" : "http"
        var urlComponents = URLComponents()

        urlComponents.scheme = scheme
        urlComponents.host = server.url
        urlComponents.port = Int(server.port)
        urlComponents.path = path

        guard let url = urlComponents.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        // 根据服务器类型设置不同的认证方式
        switch server.source {
        case .clashController, .openWRT:
            if !server.secret.isEmpty {
                request.setValue("Bearer \(server.secret)", forHTTPHeaderField: "Authorization")
            }
        case .surge:
            if let surgeKey = server.surgeKey, !surgeKey.isEmpty {
                request.setValue(surgeKey, forHTTPHeaderField: "x-key")
            }
        }

        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        return request
    }
    
    nonisolated func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let messages = [
            "收到证书验证请求",
            "认证方法: \(challenge.protectionSpace.authenticationMethod)",
            "主机: \(challenge.protectionSpace.host)",
            "端口: \(challenge.protectionSpace.port)",
            "协议: \(challenge.protectionSpace.protocol.map { $0 } ?? "unknown")"
        ]
        
        Task { @MainActor in
            for message in messages {
                logger.debug(message)
            }
        }
        
        // 无条件接受所有证书
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            if let serverTrust = challenge.protectionSpace.serverTrust {
                let credential = URLCredential(trust: serverTrust)
                completionHandler(.useCredential, credential)
                Task { @MainActor in
                    logger.debug("已接受服务器证书（包括自签证书）")
                }
            } else {
                Task { @MainActor in
                    logger.debug("无法获取服务器证书")
                }
                completionHandler(.performDefaultHandling, nil)
            }
        } else {
            Task { @MainActor in
                logger.debug("默认处理证书验证")
            }
            completionHandler(.performDefaultHandling, nil)
        }
    }
    
    @MainActor
    func checkAllServersStatus() async {
        var summaries: [ServerCheckSummary] = []
        for server in servers {
            let summary = await checkServerStatusAndSummarize(server)
            summaries.append(summary)
        }
        if !summaries.isEmpty {
            let blocks = summaries.map { s -> String in
                let status = s.success ? "成功" : "失败"
                let typeLine = s.typeText.isEmpty ? "未知" : s.typeText
                return "\(s.name)（\(status)）\n- 类型：\(typeLine)\n- 地址：\(s.address)\n- 响应代码：\(s.codeText) - \(s.detailText)\n- 耗时：\(String(format: "%.2f", s.durationSeconds))s"
            }.joined(separator: "\n\n")
            logger.info("控制器检查结果:\n\n\(blocks)")
        }
    }
    
    @MainActor
    func refreshServerStatus(for server: ClashServer) async throws {
        let s = await checkServerStatusAndSummarize(server)
        let status = s.success ? "成功" : "失败"
        let typeLine = s.typeText.isEmpty ? "未知" : s.typeText
        let block = "\(s.name)（\(status)）\n- 类型：\(typeLine)\n- 地址：\(s.address)\n- 响应代码：\(s.codeText) - \(s.detailText)\n- 耗时：\(String(format: "%.2f", s.durationSeconds))s"
        logger.info("控制器检查结果:\n\n\(block)")
    }
    
    @MainActor
    private func checkServerStatusAndSummarize(_ server: ClashServer) async -> ServerCheckSummary {
        let address: String = {
            switch server.source {
            case .clashController:
                return "\(server.url):\(server.port)"
            case .openWRT:
                let host = server.openWRTUrl ?? server.url
                let port = server.openWRTPort ?? server.port
                return "\(host):\(port)"
            case .surge:
                return "\(server.url):\(server.port)"
            }
        }()
        let startTime = Date()
        let timeout = UserDefaults.standard.double(forKey: "serverStatusTimeout")

        // 根据服务器类型选择不同的检查端点
        let checkPath: String
        switch server.source {
        case .clashController:
            checkPath = "/version"
        case .openWRT:
            checkPath = "/version" // OpenWRT 也使用 /version
        case .surge:
            checkPath = "/v1/environment" // Surge 使用 /v1/environment
        }

        guard var request = makeRequest(for: server, path: checkPath) else {
            updateServerStatus(server, status: .error, message: "无效的请求")
            return ServerCheckSummary(name: server.displayName, address: address, success: false, typeText: "", codeText: "N/A", detailText: "无效的请求", durationSeconds: 0)
        }
        request.timeoutInterval = timeout
        
        do {
            let session = makeURLSession(for: server)
            let (data, response) = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
                let task = session.dataTask(with: request) { data, response, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else if let data = data, let response = response {
                        continuation.resume(returning: (data, response))
                    } else {
                        continuation.resume(throwing: URLError(.unknown))
                    }
                }
                task.resume()
            }
            let duration = Date().timeIntervalSince(startTime)
            guard let httpResponse = response as? HTTPURLResponse else {
                updateServerStatus(server, status: .error, message: "无效的响应")
                return ServerCheckSummary(name: server.displayName, address: address, success: false, typeText: "", codeText: "0", detailText: "无效的响应", durationSeconds: duration)
            }
            let code = httpResponse.statusCode
            switch code {
            case 200:
                // 根据服务器类型处理不同的响应格式
                switch server.source {
                case .surge:
                    // Surge 返回 {"deviceName":"..."} 格式
                    if let _ = String(data: data, encoding: .utf8),
                       let deviceDict = try? JSONDecoder().decode([String: String].self, from: data),
                       let deviceName = deviceDict["deviceName"] {
                        var updatedServer = server
                        updatedServer.status = .ok
                        updatedServer.errorMessage = nil

                        // 从响应头提取 Surge 版本信息 (大小写不敏感)
                        let headers = httpResponse.allHeaderFields
                        let surgeVersionKey = headers.keys.first { ($0 as? String)?.lowercased() == "x-surge-version" } as? String
                        let surgeBuildKey = headers.keys.first { ($0 as? String)?.lowercased() == "x-surge-build" } as? String

                        if let surgeVersionKey = surgeVersionKey, let version = headers[surgeVersionKey] as? String {
                            updatedServer.surgeVersion = version
                            logger.info("更新 Surge 版本: \(version)")
                        }
                        if let surgeBuildKey = surgeBuildKey, let build = headers[surgeBuildKey] as? String {
                            updatedServer.surgeBuild = build
                            logger.info("更新 Surge 构建号: \(build)")
                        }

                        updateServer(updatedServer)
                        return ServerCheckSummary(name: server.displayName, address: address, success: true, typeText: "Surge", codeText: "\(code)", detailText: "OK(\(deviceName))", durationSeconds: duration)
                    } else {
                        updateServerStatus(server, status: .error, message: "无效的 Surge 响应格式")
                        return ServerCheckSummary(name: server.displayName, address: address, success: false, typeText: "", codeText: "\(code)", detailText: "无效的 Surge 响应格式", durationSeconds: duration)
                    }

                case .clashController, .openWRT:
                    // Clash/OpenWRT 返回版本信息
                    do {
                        let versionResponse = try JSONDecoder().decode(VersionResponse.self, from: data)
                        var updatedServer = server
                        updatedServer.status = .ok
                        updatedServer.version = versionResponse.version
                        updatedServer.serverType = determineServerType(from: versionResponse)
                        updatedServer.errorMessage = nil
                        updateServer(updatedServer)
                        let typeText: String = {
                            switch updatedServer.serverType {
                            case .meta: return "Meta"
                            case .premium: return "Premium"
                            case .singbox: return "Sing-Box"
                            case .unknown: return "Unknown"
                            default: return "Unknown"
                            }
                        }()
                        return ServerCheckSummary(name: server.displayName, address: address, success: true, typeText: typeText, codeText: "\(code)", detailText: "OK(v\(versionResponse.version), \(typeText))", durationSeconds: duration)
                    } catch {
                        if let versionDict = try? JSONDecoder().decode([String: String].self, from: data), let version = versionDict["version"] {
                            var updatedServer = server
                            updatedServer.status = .ok
                            updatedServer.version = version
                            updatedServer.errorMessage = nil
                            updateServer(updatedServer)
                            return ServerCheckSummary(name: server.displayName, address: address, success: true, typeText: "", codeText: "\(code)", detailText: "OK(v\(version))", durationSeconds: duration)
                        } else {
                            updateServerStatus(server, status: .error, message: "无效的响应格式")
                            return ServerCheckSummary(name: server.displayName, address: address, success: false, typeText: "", codeText: "\(code)", detailText: "无效的响应格式", durationSeconds: duration)
                        }
                    }
                }
            case 401:
                updateServerStatus(server, status: .unauthorized, message: "认证失败，请检查密钥")
                return ServerCheckSummary(name: server.displayName, address: address, success: false, typeText: "", codeText: "401", detailText: "认证失败，请检查密钥", durationSeconds: duration)
            case 404:
                updateServerStatus(server, status: .error, message: "API 路径不存在")
                return ServerCheckSummary(name: server.displayName, address: address, success: false, typeText: "", codeText: "404", detailText: "API 路径不存在", durationSeconds: duration)
            case 500...599:
                updateServerStatus(server, status: .error, message: "服务器错误: \(code)")
                return ServerCheckSummary(name: server.displayName, address: address, success: false, typeText: "", codeText: "\(code)", detailText: "服务器错误", durationSeconds: duration)
            default:
                updateServerStatus(server, status: .error, message: "未知响应: \(code)")
                return ServerCheckSummary(name: server.displayName, address: address, success: false, typeText: "", codeText: "\(code)", detailText: "未知响应", durationSeconds: duration)
            }
        } catch let urlError as URLError {
            let duration = Date().timeIntervalSince(startTime)
            switch urlError.code {
            case .timedOut:
                updateServerStatus(server, status: .error, message: "请求超时")
                return ServerCheckSummary(name: server.displayName, address: address, success: false, typeText: "", codeText: "\(urlError.code.rawValue)", detailText: "请求超时", durationSeconds: duration)
            case .cancelled:
                updateServerStatus(server, status: .error, message: "请求被取消")
                return ServerCheckSummary(name: server.displayName, address: address, success: false, typeText: "", codeText: "\(urlError.code.rawValue)", detailText: "请求被取消", durationSeconds: duration)
            case .secureConnectionFailed:
                updateServerStatus(server, status: .error, message: "SSL/TLS 连接失败")
                return ServerCheckSummary(name: server.displayName, address: address, success: false, typeText: "", codeText: "\(urlError.code.rawValue)", detailText: "SSL/TLS 连接失败", durationSeconds: duration)
            case .serverCertificateUntrusted:
                updateServerStatus(server, status: .error, message: "证书不信任")
                return ServerCheckSummary(name: server.displayName, address: address, success: false, typeText: "", codeText: "\(urlError.code.rawValue)", detailText: "证书不信任", durationSeconds: duration)
            case .cannotConnectToHost:
                updateServerStatus(server, status: .error, message: "无法连接到服务器")
                return ServerCheckSummary(name: server.displayName, address: address, success: false, typeText: "", codeText: "\(urlError.code.rawValue)", detailText: "无法连接到服务器", durationSeconds: duration)
            case .notConnectedToInternet:
                updateServerStatus(server, status: .error, message: "网络未连接")
                return ServerCheckSummary(name: server.displayName, address: address, success: false, typeText: "", codeText: "\(urlError.code.rawValue)", detailText: "网络未连接", durationSeconds: duration)
            default:
                updateServerStatus(server, status: .error, message: "网络错误")
                return ServerCheckSummary(name: server.displayName, address: address, success: false, typeText: "", codeText: "\(urlError.code.rawValue)", detailText: "网络错误", durationSeconds: duration)
            }
        } catch {
            let duration = Date().timeIntervalSince(startTime)
            updateServerStatus(server, status: .error, message: "未知错误")
            return ServerCheckSummary(name: server.displayName, address: address, success: false, typeText: "", codeText: "N/A", detailText: "未知错误", durationSeconds: duration)
        }
    }
    
    private func updateServerStatus(_ server: ClashServer, status: ServerStatus, message: String? = nil) {
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            var updatedServer = server
            updatedServer.status = status
            updatedServer.errorMessage = message
            servers[index] = updatedServer
            saveServers()
        }
    }
    
    @MainActor
    func loadServers() {
        // 先尝试从新的存储位置加载
        if let data = defaults.data(forKey: "servers"),
           let servers = try? JSONDecoder().decode([ClashServer].self, from: data) {
            handleLoadedServers(servers)
        } else {
            // 如果新的存储位置没有数据，尝试从旧的存储位置加载
            if let data = defaults.data(forKey: Self.saveKey),
               let servers = try? JSONDecoder().decode([ClashServer].self, from: data) {
                // 迁移数据到新的存储位置
                if let encodedData = try? JSONEncoder().encode(servers) {
                    defaults.set(encodedData, forKey: "servers")
                }
                handleLoadedServers(servers)
            }
        }
    }
    
    private func handleLoadedServers(_ servers: [ClashServer]) {
        // 直接设置服务器列表，不进行过滤
        self.servers = servers
    }
    
    private func filterServersByWiFi(_ servers: [ClashServer], ssid: String) -> [ClashServer] {
        // 查找当前 Wi-Fi 的绑定
        guard let bindingManager = bindingManager,
              let bindings = bindingManager.bindings.filter({ $0.ssid == ssid }).first else {
            return servers
        }
        
        // 获取所有绑定的服务器 ID
        let boundServerIds = Set(bindings.serverIds)
        
        // 过滤服务器列表
        return servers.filter { server in
            boundServerIds.contains(server.id.uuidString)
        }
    }
    
    private func saveServers() {
        if let encoded = try? JSONEncoder().encode(servers) {
            defaults.set(encoded, forKey: "servers")
        }
    }
    
    func addServer(_ server: ClashServer) {
        servers.append(server)
        saveServers()
        // 将新服务器添加到默认显示控制器列表中
        if let bindingManager = bindingManager {
            bindingManager.updateDefaultServers(bindingManager.defaultServerIds.union([server.id.uuidString]))
        }
        Task { [weak self] in
            guard let self = self else { return }
            let s = await self.checkServerStatusAndSummarize(server)
            let status = s.success ? "成功" : "失败"
            let typeLine = s.typeText.isEmpty ? "未知" : s.typeText
            let block = "\(s.name)（\(status)）\n- 类型：\(typeLine)\n- 地址：\(s.address)\n- 响应代码：\(s.codeText) - \(s.detailText)\n- 耗时：\(String(format: "%.2f", s.durationSeconds))s"
            self.logger.info("控制器检查结果:\n\n\(block)")
        }
    }
    
    func updateServer(_ server: ClashServer) {
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index] = server
            saveServers()
            // Task {
            //     await checkServerStatus(server)
            // }
        }
    }
    
    func deleteServer(_ server: ClashServer) {
        servers.removeAll { $0.id == server.id }
        saveServers()
    }
    
    func setQuickLaunch(_ server: ClashServer) {
        // 如果当前服务器已经是快速启动，则取消
        if server.isQuickLaunch {
            if let index = servers.firstIndex(where: { $0.id == server.id }) {
                servers[index].isQuickLaunch = false
            }
        } else {
            // 否则，先将所有服务器的 isQuickLaunch 设为 false
            for index in servers.indices {
                servers[index].isQuickLaunch = false
            }
            
            // 然后设置选中的服务器为快速启动
            if let index = servers.firstIndex(where: { $0.id == server.id }) {
                servers[index].isQuickLaunch = true
            }
        }
        
        // 保存更改
        saveServers()
    }
    
    // 添加一个辅助方法来判断服务器是否应该被隐藏
    func isServerHidden(_ server: ClashServer, currentWiFiSSID: String = "") -> Bool {
        // 检查是否因为离线状态而隐藏
        if hideDisconnectedServers && server.status != .ok {
            return true
        }
        
        // 检查是否因为 WiFi 绑定而隐藏
        let enableWiFiBinding = UserDefaults.standard.bool(forKey: "enableWiFiBinding")
        if enableWiFiBinding {
            // 优先使用注入的 bindingManager，否则回退到 UserDefaults
            let bindingsSource: [WiFiBinding]
            let defaultIdsSource: Set<String>
            if let manager = bindingManager {
                bindingsSource = manager.bindings
                defaultIdsSource = manager.defaultServerIds
            } else {
                bindingsSource = loadBindingsFromDefaults()
                defaultIdsSource = loadDefaultServerIdsFromDefaults()
                if UserDefaults.standard.bool(forKey: "wifiBindingVerboseLog") {
                    logger.debug("[WiFi绑定] bindingManager 未设置，使用 UserDefaults 回退数据：绑定=\(bindingsSource.count)，默认=\(defaultIdsSource.count)")
                }
            }
            
            // 如果未传入/获取不到当前 SSID，回退到缓存的 SSID
            let cachedSSID = UserDefaults.standard.string(forKey: "current_ssid") ?? ""
            let rawSSID = currentWiFiSSID.isEmpty ? cachedSSID : currentWiFiSSID
            let trimmedSSID = rawSSID.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercasedSSID = trimmedSSID.lowercased()
            
            if !trimmedSSID.isEmpty {
                // 如果连接了 WiFi，检查是否有绑定
                let binding = bindingsSource.first(where: { $0.ssid == trimmedSSID })
                    ?? bindingsSource.first(where: { $0.ssid.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedSSID })
                    ?? bindingsSource.first(where: { $0.ssid.lowercased() == lowercasedSSID })
                
                if let binding = binding {
                    let contains = binding.serverIds.contains(server.id.uuidString)
                    if UserDefaults.standard.bool(forKey: "wifiBindingVerboseLog") {
                        logger.debug("[WiFi绑定] 使用SSID=\(trimmedSSID) 命中绑定 SSID=\(binding.ssid)，控制器是否包含=\(contains)，当前控制器=\(server.displayName)[\(server.url):\(server.port)]")
                    }
                    return !contains
                }
                
                // 如果没有找到绑定，显示默认服务器
                let inDefault = defaultIdsSource.contains(server.id.uuidString)
                if UserDefaults.standard.bool(forKey: "wifiBindingVerboseLog") {
                    logger.debug("[WiFi绑定] 使用SSID=\(trimmedSSID) 未找到匹配绑定，使用默认控制器列表，是否在默认=\(inDefault)，当前控制器=\(server.displayName)[\(server.url):\(server.port)]")
                }
                return !inDefault
            } else {
                // 如果没有连接 WiFi，显示默认服务器
                let inDefault = defaultIdsSource.contains(server.id.uuidString)
                if UserDefaults.standard.bool(forKey: "wifiBindingVerboseLog") {
                    logger.debug("[WiFi绑定] 当前未连接 Wi-Fi（或无法获取SSID），使用默认控制器列表，是否在默认=\(inDefault)，当前控制器=\(server.displayName)[\(server.url):\(server.port)]")
                }
                return !inDefault
            }
        }
        
        return false
    }
    
    // 添加上移服务器的方法
    func moveServerUp(_ server: ClashServer) {
        guard let currentIndex = servers.firstIndex(where: { $0.id == server.id }),
              currentIndex > 0 else { return }
        
        // 从当前位置向上查找第一个可见的服务器
        var targetIndex = currentIndex - 1
        while targetIndex > 0 && isServerHidden(servers[targetIndex]) {
            targetIndex -= 1
        }
        
        // 如果目标位置的服务器也是隐藏的，不进行移动
        if isServerHidden(servers[targetIndex]) {
            return
        }
        
        servers.swapAt(currentIndex, targetIndex)
        saveServers()
    }
    
    // 添加下移服务器的方法
    func moveServerDown(_ server: ClashServer) {
        guard let currentIndex = servers.firstIndex(where: { $0.id == server.id }),
              currentIndex < servers.count - 1 else { return }
        
        // 从当前位置向下查找第一个可见的服务器
        var targetIndex = currentIndex + 1
        while targetIndex < servers.count - 1 && isServerHidden(servers[targetIndex]) {
            targetIndex += 1
        }
        
        // 如果目标位置的服务器也是隐藏的，不进行移动
        if isServerHidden(servers[targetIndex]) {
            return
        }
        
        servers.swapAt(currentIndex, targetIndex)
        saveServers()
    }
    
    // 验证 OpenWRT 服务器
    func validateSurgeServer(_ server: ClashServer) async throws -> (success: Bool, deviceName: String?, surgeVersion: String?, surgeBuild: String?) {
        let scheme = server.surgeUseSSL ? "https" : "http"
        let baseURL = "\(scheme)://\(server.url):\(server.port)/v1"
        logger.info("开始验证 Surge 服务器: \(baseURL)")
        print("🔍 [DEBUG] Surge 服务器验证 - URL: \(baseURL)")
        print("🔍 [DEBUG] Surge 服务器验证 - API Key 存在: \(server.surgeKey != nil)")
        print("🔍 [DEBUG] Surge 服务器验证 - API Key 长度: \(server.surgeKey?.count ?? 0)")
        print("🔍 [DEBUG] Surge 服务器验证 - API Key 前缀: \(server.surgeKey?.prefix(4) ?? "nil")")

        // 创建一个新的 URLSession 配置
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3  // Surge API 文档建议 3秒超时
        config.timeoutIntervalForResource = 3

        // 如果启用了 HTTPS，配置 TLS 设置
        if server.surgeUseSSL {
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            if #available(iOS 15.0, *) {
                config.tlsMinimumSupportedProtocolVersion = .TLSv12
            } else {
                config.tlsMinimumSupportedProtocolVersion = .TLSv12
            }
            config.tlsMaximumSupportedProtocolVersion = .TLSv13
        }

        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        activeSessions.append(session)

        do {
            // 创建环境信息请求
            guard let environmentURL = URL(string: "\(baseURL)/environment") else {
                logger.error("环境信息 URL 无效")
                print("❌ [DEBUG] 环境信息 URL 无效")
                return (false, nil, nil, nil)
            }

            var request = URLRequest(url: environmentURL)
            request.httpMethod = "GET"

            // Surge 使用 x-key 认证头
            if let surgeKey = server.surgeKey, !surgeKey.isEmpty {
                request.setValue(surgeKey, forHTTPHeaderField: "x-key")
                print("🔍 [DEBUG] 设置请求头 x-key: \(surgeKey.prefix(4))****")
            } else {
                print("❌ [DEBUG] 未设置 x-key 请求头 - API Key 为空或不存在")
            }

            logger.info("发送环境信息请求到: \(environmentURL.absoluteString)")
            print("🔍 [DEBUG] 完整请求 URL: \(environmentURL.absoluteString)")
            print("🔍 [DEBUG] 请求头: \(request.allHTTPHeaderFields ?? [:])")

            let (data, response) = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
                let task = session.dataTask(with: request) { data, response, error in
                    if let urlError = error as? URLError {
                        print("❌ [DEBUG] URL 错误: \(urlError.code.rawValue) - \(urlError.localizedDescription)")
                        switch urlError.code {
                        case .timedOut:
                            continuation.resume(throwing: NetworkError.timeout(message: "请求超时"))
                        case .notConnectedToInternet:
                            continuation.resume(throwing: NetworkError.invalidResponse(message: "网络未连接"))
                        case .cannotConnectToHost:
                            continuation.resume(throwing: NetworkError.invalidResponse(message: "无法连接到服务器"))
                        case .secureConnectionFailed:
                            continuation.resume(throwing: NetworkError.invalidResponse(message: "SSL/TLS 连接失败"))
                        case .serverCertificateUntrusted:
                            continuation.resume(throwing: NetworkError.invalidResponse(message: "证书不信任"))
                        default:
                            continuation.resume(throwing: NetworkError.invalidResponse(message: urlError.localizedDescription))
                        }
                    } else if let error = error {
                        print("❌ [DEBUG] 其他网络错误: \(error.localizedDescription)")
                        continuation.resume(throwing: error)
                    } else if let data = data, let response = response {
                        print("🔍 [DEBUG] 收到响应 - 数据长度: \(data.count) bytes")
                        continuation.resume(returning: (data, response))
                    } else {
                        print("❌ [DEBUG] 未知错误 - 没有数据或响应")
                        continuation.resume(throwing: URLError(.unknown))
                    }
                }
                task.resume()
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                logger.error("响应不是 HTTP 响应")
                print("❌ [DEBUG] 响应不是 HTTP 响应")
                throw NetworkError.invalidResponse(message: "无效的响应")
            }

            logger.info("Surge 服务器响应状态码: \(httpResponse.statusCode)")
            print("🔍 [DEBUG] 响应状态码: \(httpResponse.statusCode)")
            print("🔍 [DEBUG] 响应头: \(httpResponse.allHeaderFields)")

            // 打印响应体
            if let responseString = String(data: data, encoding: .utf8) {
                print("🔍 [DEBUG] 响应体: \(responseString)")
                logger.info("Surge 环境信息响应: \(responseString)")
            } else {
                print("❌ [DEBUG] 无法解析响应体")
            }

            // 检查响应状态码
            switch httpResponse.statusCode {
            case 200:
                print("✅ [DEBUG] 状态码 200 - 验证成功")

                // 解析 deviceName
                var deviceName: String? = nil
                if let _ = String(data: data, encoding: .utf8),
                   let deviceDict = try? JSONDecoder().decode([String: String].self, from: data),
                   let extractedDeviceName = deviceDict["deviceName"] {
                    deviceName = extractedDeviceName
                    print("🔍 [DEBUG] 解析到 deviceName: \(extractedDeviceName)")
                } else {
                    print("⚠️ [DEBUG] 无法解析 deviceName")
                }

                // 检查响应头中的版本信息 (大小写不敏感)
                let headers = httpResponse.allHeaderFields
                let surgeVersionKey = headers.keys.first { ($0 as? String)?.lowercased() == "x-surge-version" } as? String
                let surgeBuildKey = headers.keys.first { ($0 as? String)?.lowercased() == "x-surge-build" } as? String

                var surgeVersion: String? = nil
                var surgeBuild: String? = nil

                if let surgeVersionKey = surgeVersionKey, let version = headers[surgeVersionKey] as? String {
                    surgeVersion = version
                    logger.info("Surge 版本: \(version)")
                    print("🔍 [DEBUG] Surge 版本: \(version)")
                } else {
                    print("⚠️ [DEBUG] 未找到 x-surge-version 响应头")
                }
                if let surgeBuildKey = surgeBuildKey, let build = headers[surgeBuildKey] as? String {
                    surgeBuild = build
                    logger.info("Surge 构建号: \(build)")
                    print("🔍 [DEBUG] Surge 构建号: \(build)")
                } else {
                    print("⚠️ [DEBUG] 未找到 x-surge-build 响应头")
                }

                logger.info("Surge 服务器验证成功")
                print("✅ [DEBUG] Surge 服务器验证成功")
                return (true, deviceName, surgeVersion, surgeBuild)

            case 401:
                logger.error("Surge 服务器认证失败")
                print("❌ [DEBUG] 状态码 401 - API Key 无效")
                throw NetworkError.unauthorized(message: "API Key 无效")

            case 403:
                logger.error("Surge 服务器访问被拒绝")
                print("❌ [DEBUG] 状态码 403 - 访问被拒绝")
                throw NetworkError.invalidResponse(message: "访问被拒绝")

            default:
                logger.error("Surge 服务器返回错误状态码: \(httpResponse.statusCode)")
                print("❌ [DEBUG] 状态码 \(httpResponse.statusCode) - 未知错误")
                throw NetworkError.invalidResponse(message: "服务器返回错误: \(httpResponse.statusCode)")
            }

        } catch {
            logger.error("验证 Surge 服务器失败: \(error.localizedDescription)")
            print("❌ [DEBUG] 验证 Surge 服务器失败: \(error.localizedDescription)")
            print("❌ [DEBUG] 错误类型: \(type(of: error))")
            return (false, nil, nil, nil)
        }
    }

    func validateOpenWRTServer(_ server: ClashServer, username: String, password: String) async throws -> Bool {
        let scheme = server.openWRTUseSSL ? "https" : "http"
        guard let openWRTUrl = server.openWRTUrl else {
            throw NetworkError.invalidURL
        }
        let baseURL = "\(scheme)://\(openWRTUrl):\(server.openWRTPort ?? "80")"
        // print("第一步：开始验证 OpenwrT 服务器: \(baseURL)")
        logger.info("开始验证 OpenwrT 服务器: \(baseURL)")
        
        // 1. 使用 JSON-RPC 登录
        guard let loginURL = URL(string: "\(baseURL)/cgi-bin/luci/rpc/auth") else {
            // print("登录 URL 无效")
            logger.error("登录 URL 无效")
            throw NetworkError.invalidURL
        }
        
        // 创建一个新的 URLSession 配置
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10  // 设置超时时间为 10 秒
        config.timeoutIntervalForResource = 10  // 设置资源超时时间为 10 秒
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        activeSessions.append(session)
        
        do {
            // 创建 JSON-RPC 登录请求
            var loginRequest = URLRequest(url: loginURL)
            loginRequest.httpMethod = "POST"
            loginRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            
            // 构建 JSON-RPC 请求体
            let requestBody: [String: Any] = [
                "id": 1,
                "method": "login",
                "params": [username, password]
            ]
            
            loginRequest.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
            
            
            let (loginData, loginResponse) = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
                let task = session.dataTask(with: loginRequest) { data, response, error in
                    if let error = error as? URLError, error.code == .timedOut {
                        continuation.resume(throwing: NetworkError.timeout(message: "请求超时"))
                    } else if let error = error {
                        continuation.resume(throwing: error)
                    } else if let data = data, let response = response {
                        continuation.resume(returning: (data, response))
                    } else {
                        continuation.resume(throwing: URLError(.unknown))
                    }
                }
                task.resume()
            }
            
            guard let httpResponse = loginResponse as? HTTPURLResponse else {
                // print("无效的响应类型")
                logger.error("无效的响应类型")
                throw NetworkError.invalidResponse(message: "无效的响应类型")
            }
            
            print("登录响应状态码: \(httpResponse.statusCode)")
            if let responseStr = String(data: loginData, encoding: .utf8) {
                // print("JSON-RPC 登录响应: \(responseStr)")
                logger.info("JSON-RPC 登录响应: \(responseStr)")
            }
            
            switch httpResponse.statusCode {
            case 200:
                // 解析 JSON-RPC 响应
                let authResponse: OpenWRTAuthResponse
                do {
                    authResponse = try JSONDecoder().decode(OpenWRTAuthResponse.self, from: loginData)
                } catch {
                    // print("JSON-RPC 响应解析失败")
                    logger.error("JSON-RPC 响应解析失败")
                    throw NetworkError.invalidResponse(message: "验证 OpenWRT 信息失败，请确认输入的信息是否正确")
                }
                
                guard let token = authResponse.result, !token.isEmpty else {
                    if authResponse.result == nil && authResponse.error == nil {
                        // print("认证响应异常: result 和 error 都为 nil")
                        if let responseStr = String(data: loginData, encoding: .utf8) {
                            // print("原始响应内容: \(responseStr)")
                            logger.info("原始响应内容: \(responseStr)")
                            throw NetworkError.unauthorized(message: "认证失败: 请检查用户名或密码是否正确") 
                        } else {
                            logger.error("认证响应异常: result 和 error 都为 nil")
                            throw NetworkError.unauthorized(message: "认证失败: 响应内容为空")
                        }
                    }
                    if let error = authResponse.error {
                        // print("JSON-RPC 错误: \(error)")
                        logger.error("JSON-RPC 错误: \(error)")
                        throw NetworkError.invalidResponse(message: "JSON-RPC 获取错误，请确认 OpenWRT 信息是否正确")
                    }
                    // print("无效的响应结果")
                    logger.error("无效的响应结果")
                    throw NetworkError.invalidResponse(message: "无效的响应结果")
                }
                
                // print("获取认证令牌: \(token)")
                logger.info("获取到认证令牌: \(token)")
                
                // 根据不同的 LuCI 软件包类型调用不同的 API
                switch server.luciPackage {
                case .openClash:
                    // 检查 OpenClash 进程状态
                    guard let url = URL(string: "\(baseURL)/cgi-bin/luci/rpc/sys?auth=\(token)") else {
                        throw NetworkError.invalidURL
                    }
                    var statusRequest = URLRequest(url: url)
                    statusRequest.httpMethod = "POST"
                    statusRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    statusRequest.setValue("sysauth=\(token); sysauth_http=\(token); sysauth_https=\(token)", forHTTPHeaderField: "Cookie")
                    
                    let statusCommand: [String: Any] = [
                        "method": "exec",
                        "params": ["pidof clash >/dev/null && echo 'running' || echo 'stopped'"]
                    ]
                    statusRequest.httpBody = try JSONSerialization.data(withJSONObject: statusCommand)
                    
                    let (statusData, _) = try await session.data(for: statusRequest)
                    let statusResponse = try JSONDecoder().decode(ClashStatusResponse.self, from: statusData)
                    
                    if statusResponse.result.contains("stopped") {
                        throw NetworkError.unauthorized(message: "OpenClash 未在运行，请先启用 OpenClash 再添加")
                    }
                    
                    // OpenClash 正在运行，返回 true
                    return true
                    
                case .mihomoTProxy:
                    // 检查 MihomoTProxy 进程状态
                    guard let url = URL(string: "\(baseURL)/cgi-bin/luci/rpc/sys?auth=\(token)") else {
                        throw NetworkError.invalidURL
                    }
                    var statusRequest = URLRequest(url: url)
                    statusRequest.httpMethod = "POST"
                    statusRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    statusRequest.setValue("sysauth=\(token); sysauth_http=\(token); sysauth_https=\(token)", forHTTPHeaderField: "Cookie")
                    
                    let statusCommand: [String: Any] = [
                        "method": "exec",
                        "params": ["pidof mihomo >/dev/null && echo 'running' || echo 'stopped'"]
                    ]
                    statusRequest.httpBody = try JSONSerialization.data(withJSONObject: statusCommand)
                    
                    let (statusData, _) = try await session.data(for: statusRequest)
                    let statusResponse = try JSONDecoder().decode(ClashStatusResponse.self, from: statusData)
                    
                    if statusResponse.result.contains("stopped") {
                        throw NetworkError.unauthorized(message: "Nikki 未在运行，请先启用 Nikki")
                    }
                    
                    // MihomoTProxy 正在运行，返回 true
                    return true
                }
                
            case 404:
                print("OpenWRT 缺少必要的依赖")
                logger.error("OpenWRT 缺少必要的依赖或信息错误")
                throw NetworkError.missingDependencies("""
                    请求 404 错误

                    请确保信息正确，并已经安装以下软件包：
                    1. luci-mod-rpc
                    2. luci-lib-ipkg
                    3. luci-compat

                    并重启 uhttpd
                    """)
                
            default:
                // print("登录失败：状态码 \(httpResponse.statusCode)")
                throw NetworkError.serverError(httpResponse.statusCode)
            }
        } catch let urlError as URLError {
            if urlError.code == .timedOut {
                throw NetworkError.timeout(message: "请求超时")
            }
            throw urlError
        }
    }
    
    // 添加获取 Clash 配置的方法
//    func fetchClashConfig(_ server: ClashServer) async throws -> ClashConfig {
//        guard let username = server.openWRTUsername,
//              let password = server.openWRTPassword else {
//            throw NetworkError.unauthorized(message: "未设置 OpenWRT 用户名或密码")
//        }
//        
//        let scheme = server.openWRTUseSSL ? "https" : "http"
//        guard let openWRTUrl = server.openWRTUrl else {
//            throw NetworkError.invalidURL
//        }
//        let baseURL = "\(scheme)://\(openWRTUrl):\(server.openWRTPort ?? "80")"
//        guard let url = URL(string: "\(baseURL)/cgi-bin/luci/admin/services/openclash/config") else {
//            throw NetworkError.invalidURL
//        }
//        
//        var request = URLRequest(url: url)
//        
//        // 添加基本认证
//        let authString = "\(username):\(password)"
//        if let authData = authString.data(using: .utf8) {
//            let base64Auth = authData.base64EncodedString()
//            request.setValue("Basic \(base64Auth)", forHTTPHeaderField: "Authorization")
//        }
//        
//        let session = makeURLSession(for: server)
//        
//        do {
//            let (data, response) = try await session.data(for: request)
//            
//            guard let httpResponse = response as? HTTPURLResponse else {
//                throw NetworkError.invalidResponse(message: "无效的响应类型")
//            }
//            
//            switch httpResponse.statusCode {
//            case 200:
//                return try JSONDecoder().decode(ClashConfig.self, from: data)
//            case 401:
//                throw NetworkError.unauthorized(message: "认证失败: 服务器返回 401 未授权")
//            default:
//                throw NetworkError.serverError(httpResponse.statusCode)
//            }
//        } catch {
//            throw ClashServer.handleNetworkError(error)
//        }
//    }
    
//    nonisolated func urlSession(
//        _ session: URLSession,
//        task: URLSessionTask,
//        willPerformHTTPRedirection response: HTTPURLResponse,
//        newRequest request: URLRequest,
//        completionHandler: @escaping (URLRequest?) -> Void
//    ) {
//        print("收到重定向请求")
//        print("从: \(task.originalRequest?.url?.absoluteString ?? "unknown")")
//        print("到: \(request.url?.absoluteString ?? "unknown")")
//        print("状态码: \(response.statusCode)")
//        completionHandler(nil)  // 不跟随重定向
//    }
    
    func fetchOpenClashConfigs(_ server: ClashServer) async throws -> [OpenClashConfig] {
        let scheme = server.openWRTUseSSL ? "https" : "http"
        guard let openWRTUrl = server.openWRTUrl else {
            throw NetworkError.invalidURL
        }
        let baseURL = "\(scheme)://\(openWRTUrl):\(server.openWRTPort ?? "80")"
        
        // print("🔍 开始获取配置列表: \(baseURL)")
        logger.info("🔍 开始获取配置列表: \(baseURL)")
        
        // 1. 获取认证 token
        guard let username = server.openWRTUsername,
              let password = server.openWRTPassword else {
            print("未找到认证信息")
            logger.error("未找到认证信息")
            throw NetworkError.unauthorized(message: "未设置 OpenWRT 用户名或密码")
        }
        
        // print("获取认证令牌...")
        // logger.log("获取认证令牌...")
        let token = try await getAuthToken(server, username: username, password: password)
        // print("获取令牌成功: \(token)")
        // logger.log("获取令牌成功: \(token)")
        
        let session = makeURLSession(for: server)
        
        // 2. 获取配置文件列表
        guard let fsURL = URL(string: "\(baseURL)/cgi-bin/luci/rpc/fs?auth=\(token)") else {
            throw NetworkError.invalidURL
        }
        
        var fsRequest = URLRequest(url: fsURL)
        fsRequest.httpMethod = "POST"
        fsRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        fsRequest.setValue("sysauth=\(token); sysauth_http=\(token); sysauth_https=\(token)", forHTTPHeaderField: "Cookie")
        
        let fsCommand: [String: Any] = [
            "method": "glob",
            "params": ["/etc/openclash/config/*"]
        ]
        fsRequest.httpBody = try JSONSerialization.data(withJSONObject: fsCommand)
        
        print("📤 获取文件列表...")
        logger.info("📤 获取文件列表...")
        let (fsData, _) = try await session.data(for: fsRequest)
        
        // 解析 glob 响应
        let fsResponse = try JSONDecoder().decode(FSGlobResponse.self, from: fsData)
        let (fileList, fileCount) = fsResponse.result
        
        // print("📝 找到 \(fileCount) 个配置文件")
        logger.info("📝 找到 \(fileCount) 个配置文件")
        
        // 3. 获取当前启用的配置
        guard let sysURL = URL(string: "\(baseURL)/cgi-bin/luci/rpc/sys?auth=\(token)") else {
            throw NetworkError.invalidURL
        }
        var sysRequest = URLRequest(url: sysURL)
        sysRequest.httpMethod = "POST"
        sysRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        sysRequest.setValue("sysauth=\(token); sysauth_http=\(token); sysauth_https=\(token)", forHTTPHeaderField: "Cookie")
        
        let sysCommand: [String: Any] = [
            "method": "exec",
            "params": ["uci get openclash.config.config_path"]
        ]
        sysRequest.httpBody = try JSONSerialization.data(withJSONObject: sysCommand)
        
        let (sysData, _) = try await session.data(for: sysRequest)
        let sysResult = try JSONDecoder().decode(ListResponse.self, from: sysData)
        let currentConfig = sysResult.result.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).components(separatedBy: "/").last ?? ""
        
        // print("📝 当前启用的配置: \(currentConfig)")
        logger.info("📝 当前启用的配置: \(currentConfig)")
        
        // 4. 处理每个配置文件
        var configs: [OpenClashConfig] = []
        for filePath in fileList {
            let fileName = filePath.components(separatedBy: "/").last ?? ""
            guard fileName.hasSuffix(".yaml") || fileName.hasSuffix(".yml") else { continue }
            
            // print("📄 处理配置文件: \(fileName)")
            logger.debug("📄 处理配置文件: \(fileName)")
            
            // 获取文件元数据
            var statRequest = URLRequest(url: fsURL)
            statRequest.httpMethod = "POST"
            statRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            statRequest.setValue("sysauth=\(token); sysauth_http=\(token); sysauth_https=\(token)", forHTTPHeaderField: "Cookie")
            
            let statCommand: [String: Any] = [
                "method": "stat",
                "params": [filePath]
            ]
            statRequest.httpBody = try JSONSerialization.data(withJSONObject: statCommand)
            
            let (statData, _) = try await session.data(for: statRequest)
            let statResponse = try JSONDecoder().decode(FSStatResponse.self, from: statData)

            logger.debug("配置文件元数据: \(statResponse.result)")
            
            // 检查配置文件语法（使用本地 Yams 验证）
            logger.debug("🔍 检查配置文件语法: \(fileName)")
            let check: OpenClashConfig.ConfigCheck
            do {
                // 获取配置文件内容进行本地验证
                let configContent = try await fetchConfigContent(
                    server,
                    configFilename: fileName,
                    packageName: "openclash",
                    isSubscription: false
                )
                
                // 使用 Yams 进行本地验证
                let validationResult = YAMLValidator.validateClashConfig(configContent)
                check = validationResult.isValid ? .normal : .abnormal
                
                if !validationResult.isValid {
                    logger.warning("配置文件语法错误 \(fileName): \(validationResult.error ?? "未知错误")")
                } else if let warning = validationResult.error {
                    logger.info("配置文件警告 \(fileName): \(warning)")
                }
            } catch {
                logger.error("验证配置文件 \(fileName) 时出错: \(error)")
                check = .abnormal
            }
            
            // 获取订阅信息
            // print("获取订阅信息: \(fileName)")
            logger.debug("获取订阅信息: \(fileName)")
            let subFileName = fileName.replacingOccurrences(of: ".yaml", with: "").replacingOccurrences(of: ".yml", with: "")
            let timestamp = Int(Date().timeIntervalSince1970 * 1000)
            guard let subURL = URL(string: "\(baseURL)/cgi-bin/luci/admin/services/openclash/sub_info_get?\(timestamp)&filename=\(subFileName)") else {
                continue
            }
            
            var subRequest = URLRequest(url: subURL)
            subRequest.setValue("sysauth=\(token); sysauth_http=\(token); sysauth_https=\(token)", forHTTPHeaderField: "Cookie")
            
            let subscription: OpenClashConfig.SubscriptionInfo?
            do {
                let (subData, _) = try await session.data(for: subRequest)
                subscription = try JSONDecoder().decode(OpenClashConfig.SubscriptionInfo.self, from: subData)
                logger.debug("订阅信息解码成功: \(String(describing: subscription))")
            } catch {
                logger.warning("获取订阅信息失败: \(error.localizedDescription)")
                // 设置一个默认的订阅信息
                subscription = OpenClashConfig.SubscriptionInfo(
                    surplus: nil,      // 第一个参数
                    total: nil,        // 第二个参数
                    dayLeft: nil,      // 第三个参数
                    httpCode: nil,     // 第四个参数
                    used: nil,         // 第五个参数
                    expire: nil,       // 第六个参数
                    subInfo: "No Sub Info Found",  // 第七个参数
                    percent: nil       // 第八个参数
                )
            }
            
            // 创建配置对象
            let config = OpenClashConfig(
                name: fileName,
                state: fileName == currentConfig ? .enabled : .disabled,
                mtime: Date(timeIntervalSince1970: TimeInterval(statResponse.result.mtime)),
                check: check,
                subscription: subscription,
                fileSize: Int64(statResponse.result.size)
            )
            
            // 根据订阅信息判断是否为订阅配置
            var updatedConfig = config
            updatedConfig.isSubscription = subscription?.subInfo != "No Sub Info Found"
            configs.append(updatedConfig)
            // print("成功添加配置: \(fileName)")
            logger.info("成功添加配置: \(fileName)")
        }
        
        // print("完成配置列表获取，共 \(configs.count) 个配置")
        logger.info("完成配置列表获取，共 \(configs.count) 个配置")
        return configs
    }
    
    func switchClashConfig(_ server: ClashServer, configFilename: String, packageName: String, isSubscription: Bool) async throws -> AsyncThrowingStream<String, Error> {
        let scheme = server.openWRTUseSSL ? "https" : "http"
        guard let openWRTUrl = server.openWRTUrl else { 
            throw NetworkError.invalidURL
        }
        let baseURL = "\(scheme)://\(openWRTUrl):\(server.openWRTPort ?? "80")"
        // print("开始切换配置: \(configFilename)")
        logger.info("开始切换配置: \(configFilename)")
        // 获取认证 token
        guard let username = server.openWRTUsername,
              let password = server.openWRTPassword else {
            throw NetworkError.unauthorized(message: "未设置 OpenWRT 用户名或密码")
        }
        
        let token = try await getAuthToken(server, username: username, password: password)
        
        // 1. 发送切换配置请求
        if packageName == "openclash" {
            let timestamp = Int(Date().timeIntervalSince1970 * 1000)
            guard let switchURL = URL(string: "\(baseURL)/cgi-bin/luci/admin/services/openclash/switch_config?\(timestamp)") else {
                throw NetworkError.invalidURL
            }
            
            var request = URLRequest(url: switchURL)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.setValue("sysauth=\(token); sysauth_http=\(token); sysauth_https=\(token)", forHTTPHeaderField: "Cookie")
            request.httpBody = "config_name=\(configFilename)".data(using: .utf8)
            
            let session = makeURLSession(for: server)
            let (_, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse,
                httpResponse.statusCode == 200 else {
                throw NetworkError.serverError((response as? HTTPURLResponse)?.statusCode ?? 500)
            }

        


        } else {
            // mihomoTProxy
            
            let switchCommand: String
            
            // 检查是否使用 nikki
            let isNikki = try await isUsingNikki(server, token: token)
            let packagePrefix = isNikki ? "nikki" : "mihomo"
            
            // 判断是否为订阅配置
            if isSubscription {
                switchCommand = "uci set \(packagePrefix).config.profile=subscription:\(configFilename.replacingOccurrences(of: ".yaml", with: "").replacingOccurrences(of: ".yml", with: "")) && uci commit \(packagePrefix)"
            } else {
                switchCommand = "uci set \(packagePrefix).config.profile=file:\(configFilename) && uci commit \(packagePrefix)"
            }

            // print("切换配置命令: \(switchCommand)")

            _ = try await makeUCIRequest(server, token: token, method: "sys", params: ["exec", [switchCommand]])
            // print("切换配置响应: \(switchRequest)")

        }

        // 2. 使用 restartOpenClash 来重启服务并监控状态
        let restartStream = try await restartOpenClash(server, packageName: packageName, isSubscription: isSubscription)
        
        // 3. 使用 AsyncThrowingStream 转换为 AsyncStream
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await message in restartStream {
                        continuation.yield(message)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
        
        
    }
    
    // 将 getAuthToken 改为 public
    public func getAuthToken(_ server: ClashServer, username: String, password: String) async throws -> String {
        let scheme = server.openWRTUseSSL ? "https" : "http"
        guard let openWRTUrl = server.openWRTUrl else {
            throw NetworkError.invalidURL
        }
        let baseURL = "\(scheme)://\(openWRTUrl):\(server.openWRTPort ?? "80")"
        
        guard let loginURL = URL(string: "\(baseURL)/cgi-bin/luci/rpc/auth") else {
            throw NetworkError.invalidURL
        }
        
        var loginRequest = URLRequest(url: loginURL)
        loginRequest.httpMethod = "POST"
        loginRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let requestBody: [String: Any] = [
            "id": 1,
            "method": "login",
            "params": [username, password]
        ]
        
        loginRequest.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        
        let session = makeURLSession(for: server)
        let (data, _) = try await session.data(for: loginRequest)
        let authResponse = try JSONDecoder().decode(OpenWRTAuthResponse.self, from: data)
        
        guard let token = authResponse.result, !token.isEmpty else {
            if let error = authResponse.error {
                throw NetworkError.unauthorized(message: "认证失败: \(error)")
            }
            throw NetworkError.unauthorized(message: "认证失败: 服务器没有返回有效的认证令牌")
        }
        
        return token
    }
    
    func fetchConfigContent(_ server: ClashServer, configFilename: String, packageName: String, isSubscription: Bool) async throws -> String {
        let scheme = server.openWRTUseSSL ? "https" : "http"
        guard let openWRTUrl = server.openWRTUrl else {
            throw NetworkError.invalidURL
        }
        let baseURL = "\(scheme)://\(openWRTUrl):\(server.openWRTPort ?? "80")"
        
        // 获取认证 token
        guard let username = server.openWRTUsername,
              let password = server.openWRTPassword else {
            throw NetworkError.unauthorized(message: "未设置 OpenWRT 用户名或密码")
        }
        
        let token = try await getAuthToken(server, username: username, password: password)
        
        // 构建请求
        guard let url = URL(string: "\(baseURL)/cgi-bin/luci/rpc/sys?auth=\(token)") else {
            throw NetworkError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("sysauth=\(token); sysauth_http=\(token); sysauth_https=\(token)", forHTTPHeaderField: "Cookie")
        
        // 根据包名和是否为订阅构建文件路径
        let configPath: String
        if packageName == "openclash" {
            configPath = "/etc/openclash/config/\(configFilename)"
        } else {
            // mihomoTProxy
            // 检查是否使用 nikki
            let isNikki = try await isUsingNikki(server, token: token)
            let packagePrefix = isNikki ? "nikki" : "mihomo"
            
            configPath = isSubscription ? 
                "/etc/\(packagePrefix)/subscriptions/\(configFilename)" :
                "/etc/\(packagePrefix)/profiles/\(configFilename)"
        }

        let command: [String: Any] = [
            "method": "exec",
            "params": ["cat '\(configPath)'"]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: command)
        
        let session = makeURLSession(for: server)
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw NetworkError.serverError((response as? HTTPURLResponse)?.statusCode ?? 500)
        }
        
        struct ConfigResponse: Codable {
            let id: Int?
            let result: String
            let error: String?
        }
        
        let configResponse = try JSONDecoder().decode(ConfigResponse.self, from: data)
        return configResponse.result
    }
    
    func saveConfigContent(_ server: ClashServer, configFilename: String, content: String, packageName: String, isSubscription: Bool) async throws {
        let scheme = server.openWRTUseSSL ? "https" : "http"
        guard let openWRTUrl = server.openWRTUrl else {
            throw NetworkError.invalidURL
        }
        let baseURL = "\(scheme)://\(openWRTUrl):\(server.openWRTPort ?? "80")"
        
        logger.info("📝 开始保存配置文件: \(configFilename)")
        guard let username = server.openWRTUsername,
              let password = server.openWRTPassword else {
            logger.error("未找到认证信息")
            throw NetworkError.unauthorized(message: "未找到认证信息")
        }
        
        let token = try await getAuthToken(server, username: username, password: password)
        
        // 构建请求
        guard let url = URL(string: "\(baseURL)/cgi-bin/luci/rpc/sys?auth=\(token)") else {
            throw NetworkError.invalidURL
        }
        
        // 转义内容中的特殊字符
        let escapedContent = content.replacingOccurrences(of: "'", with: "'\\''")
        
        // 根据包名和是否为订阅构建文件路径
        let configPath: String
        if packageName == "openclash" {
            configPath = "'/etc/openclash/config/\(configFilename)'"
        } else {
            // mihomoTProxy
            // 检查是否使用 nikki
            let isNikki = try await isUsingNikki(server, token: token)
            let packagePrefix = isNikki ? "nikki" : "mihomo"
            
            configPath = isSubscription ? 
                "'/etc/\(packagePrefix)/subscriptions/\(configFilename)'" :
                "'/etc/\(packagePrefix)/profiles/\(configFilename)'"
        }

        // 构建写入命令,使用 echo 直接写入
        let cmd = "echo '\(escapedContent)' > \(configPath) 2>&1 && echo '写入成功' || echo '写入失败'"
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST" 
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("sysauth=\(token); sysauth_http=\(token); sysauth_https=\(token)", forHTTPHeaderField: "Cookie")
        
        let command: [String: Any] = [
            "method": "exec",
            "params": [cmd]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: command)
        
        let session = makeURLSession(for: server)
        let (_, response) = try await session.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse {
            logger.info("写入响应状态码: \(httpResponse.statusCode)")
        }
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            logger.error("写入失败")
            throw NetworkError.serverError((response as? HTTPURLResponse)?.statusCode ?? 500)
        }
        
        // 验证文件是否成功写入
        logger.info("🔍 验证文件写入...")
        
        // 使用 fs.stat 验证文件
        guard let fsURL = URL(string: "\(baseURL)/cgi-bin/luci/rpc/fs?auth=\(token)") else {
            throw NetworkError.invalidURL
        }
        
        var statRequest = URLRequest(url: fsURL)
        statRequest.httpMethod = "POST"
        statRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        statRequest.setValue("sysauth=\(token); sysauth_http=\(token); sysauth_https=\(token)", forHTTPHeaderField: "Cookie")
        
        let statCommand: [String: Any] = [
            "method": "stat",
            "params": [configPath.replacingOccurrences(of: "'", with: "")]
        ]
        statRequest.httpBody = try JSONSerialization.data(withJSONObject: statCommand)
        
        let (statData, _) = try await session.data(for: statRequest)
        let statResponse = try JSONDecoder().decode(FSStatResponse.self, from: statData)
        
        // 检查文件修改时间
        let fileDate = Date(timeIntervalSince1970: TimeInterval(statResponse.result.mtime))
        let timeDiff = Date().timeIntervalSince(fileDate)
        
        logger.info("文件修改时间差: \(timeDiff)秒")
        
        if timeDiff < 0 || timeDiff > 5 {
            logger.error("文件时间验证失败")
            throw NetworkError.invalidResponse(message: "文件时间验证失败")
        }
        
        logger.info("配置文件保存成功")
    }
    
    func restartOpenClash(_ server: ClashServer, packageName: String, isSubscription: Bool) async throws -> AsyncThrowingStream<String, Error> {
//        let scheme = server.openWRTUseSSL ? "https" : "http"
//        guard let openWRTUrl = server.openWRTUrl else {
//            throw NetworkError.invalidURL
//        }
//        let baseURL = "\(scheme)://\(openWRTUrl):\(server.openWRTPort ?? "80")"
        
        // print("开始重启 OpenClash")

        guard let username = server.openWRTUsername,
            let password = server.openWRTPassword else {
            // print("未找到认证信息")
            throw NetworkError.unauthorized(message: "未设置 OpenWRT 用户名或密码")
        }
        
        // print("获取认证令牌...")
        let token = try await getAuthToken(server, username: username, password: password)
        // print("获取令牌成功: \(token)")

        if packageName == "openclash" {
            let scheme = server.openWRTUseSSL ? "https" : "http"
            guard let openWRTUrl = server.openWRTUrl else {
                throw NetworkError.invalidURL
            }
            let baseURL = "\(scheme)://\(openWRTUrl):\(server.openWRTPort ?? "80")"
            
            // print("开始重启 OpenClash")

            guard let username = server.openWRTUsername,
                let password = server.openWRTPassword else {
                // print("未找到认证信息")
                throw NetworkError.unauthorized(message: "未设置 OpenWRT 用户名或密码")
            }
            
            // print("获取认证令牌...")
            let token = try await getAuthToken(server, username: username, password: password)
            // print("获取令牌成功: \(token)")
            
            guard let restartURL = URL(string: "\(baseURL)/cgi-bin/luci/rpc/sys?auth=\(token)") else {
                throw NetworkError.invalidURL
            }
            
            var restartRequest = URLRequest(url: restartURL)
            restartRequest.httpMethod = "POST"
            restartRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            restartRequest.setValue("sysauth=\(token); sysauth_http=\(token); sysauth_https=\(token)", forHTTPHeaderField: "Cookie")
            
            let restartCommand: [String: Any] = [
                "method": "exec",
                "params": ["/etc/init.d/openclash restart >/dev/null 2>&1 &"]
            ]
            restartRequest.httpBody = try JSONSerialization.data(withJSONObject: restartCommand)
            
            let session = makeURLSession(for: server)
            let (_, restartResponse) = try await session.data(for: restartRequest)
            
            guard (restartResponse as? HTTPURLResponse)?.statusCode == 200 else {
                throw NetworkError.serverError((restartResponse as? HTTPURLResponse)?.statusCode ?? 500)
            }
            
            print("重启命令已发送")
            logger.info("重启命令已发送")
            
            // 返回一个异步流来监控启动日志和服务状态
            return AsyncThrowingStream { continuation in
                Task {
                    var isRunning = false
                    var hasWaitedAfterRunning = false
                    var seenLogs = Set<String>()
                    var waitStartTime: Date? = nil
                    
                    while !isRunning || !hasWaitedAfterRunning {
                        do {
                            // 获取启动日志
                            let random = Int.random(in: 1...1000000000)
                            guard let logURL = URL(string: "\(baseURL)/cgi-bin/luci/admin/services/openclash/startlog?\(random)") else {
                                throw NetworkError.invalidURL
                            }
                            
                            var logRequest = URLRequest(url: logURL)
                            logRequest.setValue("sysauth=\(token); sysauth_http=\(token); sysauth_https=\(token)", forHTTPHeaderField: "Cookie")
                            
                            let (logData, _) = try await session.data(for: logRequest)
                            let logResponse = try JSONDecoder().decode(StartLogResponse.self, from: logData)
                            
                            // 处理日志
                            if !logResponse.startlog.isEmpty {
                                let logs = logResponse.startlog
                                    .components(separatedBy: "\n")
                                    .filter { !$0.isEmpty && $0 != "\n" }
                                
                                for log in logs {
                                    let trimmedLog = log.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if !trimmedLog.isEmpty && !seenLogs.contains(trimmedLog) {
                                        seenLogs.insert(trimmedLog)
                                        continuation.yield(trimmedLog)
                                        
                                        // 检查日志是否包含成功标记
                                        if trimmedLog.contains("启动成功") {
                                            continuation.yield("OpenClash 服务已完全就绪")
                                            continuation.finish()
                                            return
                                        }
                                    }
                                }
                            }
                            
                            // 检查服务状态
                            var statusRequest = URLRequest(url: restartURL)
                            statusRequest.httpMethod = "POST"
                            statusRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                            statusRequest.setValue("sysauth=\(token); sysauth_http=\(token); sysauth_https=\(token)", forHTTPHeaderField: "Cookie")
                            
                            let statusCommand: [String: Any] = [
                                "method": "exec",
                                "params": ["pidof clash >/dev/null && echo 'running' || echo 'stopped'"]
                            ]
                            statusRequest.httpBody = try JSONSerialization.data(withJSONObject: statusCommand)
                            
                            let (statusData, _) = try await session.data(for: statusRequest)
                            let statusResponse = try JSONDecoder().decode(ClashStatusResponse.self, from: statusData)
                            
                            if statusResponse.result.contains("running") {
                                if !isRunning {
                                    isRunning = true
                                    waitStartTime = Date()
                                }
                                
                                // 检查是否已经等待足够时间
                                if let startTime = waitStartTime {
                                    let elapsedTime = Date().timeIntervalSince(startTime)
                                    if elapsedTime >= 20 {  // 等待20秒确保服务完全启动
                                        hasWaitedAfterRunning = true
                                        continuation.yield("OpenClash 服务已就绪")
                                        continuation.finish()
                                        break
                                    }
                                }
                            }
                            
                            try await Task.sleep(nanoseconds: 100_000_000) // 0.1秒延迟
                            
                        } catch {
                            continuation.yield("发生错误: \(error.localizedDescription)")
                            continuation.finish()
                            break
                        }
                    }
                }
            }
        } else {
            // mihomoTProxy
            //  1. 清理日志
            _ = try await makeUCIRequest(server, token: token, method: "sys", params: ["exec", ["/usr/libexec/mihomo-call clear_log app"]])
            
            // 检查是否使用 nikki
            let isNikki = try await isUsingNikki(server, token: token)
            let packagePrefix = isNikki ? "nikki" : "mihomo"
            
            // 2. 进行服务重载
            _ = try await makeUCIRequest(server, token: token, method: "sys", params: ["exec", ["/etc/init.d/\(packagePrefix) reload"]])

            // 3. 返回异步流来监控日志
            return AsyncThrowingStream { continuation in
                Task {
                    do {
                        // 记录已经显示过的日志，避免重复
                        var seenLogs = Set<String>()
                        
                        // 发送第一条日志
                        continuation.yield("切换配置文件...")
                        
                        // 发送第二条日志
                        continuation.yield("🧹 清理 \(isNikki ? "Nikki" : "Mihomo") 运行日志...")
                        
                        // 发送第三条日志
                        continuation.yield("重载 \(isNikki ? "Nikki" : "Mihomo") 服务...")
                        
                        // 循环获取日志，直到看到成功启动的消息
                        while true {
                            // 获取应用日志
                            let getAppLog = try await makeUCIRequest(server, token: token, method: "sys", params: ["exec", ["cat /var/log/\(packagePrefix)/app.log"]])
                            
                            if let result = getAppLog["result"] as? String {
                                // 将日志按行分割并处理
                                let logs = result.components(separatedBy: "\n")
                                    .filter { !$0.isEmpty }
                                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                
                                // 处理每一行日志
                                for log in logs {
                                    // 如果这条日志还没有显示过
                                    if !seenLogs.contains(log) {
                                        seenLogs.insert(log)
                                        continuation.yield(log)
                                        
                                        // 如果看到成功启动的消息，结束监控
                                        if log.contains("[App] Start Successful") {
                                            continuation.yield("\(isNikki ? "Nikki" : "Mihomo") 服务已完全启动")
                                            continuation.finish()
                                            return
                                        }
                                        
                                        // 每条日志显示后等待 0.2 秒
                                        try await Task.sleep(nanoseconds: 200_000_000)
                                    }
                                }
                            }
                            
                            // 等待 0.1 秒后再次获取日志
                            try await Task.sleep(nanoseconds: 100_000_000)
                        }

                        try await Task.sleep(nanoseconds: 2000_000_000)


                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
        }
    }
    
    private func getOpenClashStatus(_ server: ClashServer) async throws -> ClashStatusResponse {
        let scheme = server.openWRTUseSSL ? "https" : "http"
        guard let openWRTUrl = server.openWRTUrl else {
            throw NetworkError.invalidURL
        }
        let baseURL = "\(scheme)://\(openWRTUrl):\(server.openWRTPort ?? "80")"
        
        guard let username = server.openWRTUsername,
              let password = server.openWRTPassword else {
            throw NetworkError.unauthorized(message: "未设置 OpenWRT 用户名或密码")
        }
        
        let token = try await getAuthToken(server, username: username, password: password)
        
        guard let url = URL(string: "\(baseURL)/cgi-bin/luci/rpc/sys?auth=\(token)") else {
            throw NetworkError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("sysauth=\(token); sysauth_http=\(token); sysauth_https=\(token)", forHTTPHeaderField: "Cookie")
        
        let command: [String: Any] = [
            "method": "exec",
            "params": ["/etc/init.d/openclash status"]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: command)
        
        let session = makeURLSession(for: server)
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw NetworkError.serverError((response as? HTTPURLResponse)?.statusCode ?? 500)
        }
        
        return try JSONDecoder().decode(ClashStatusResponse.self, from: data)
    }
    
    func deleteOpenClashConfig(_ server: ClashServer, configFilename: String, packageName: String, isSubscription: Bool) async throws {
        let scheme = server.openWRTUseSSL ? "https" : "http"
        guard let openWRTUrl = server.openWRTUrl else {
            throw NetworkError.invalidURL
        }
        let baseURL = "\(scheme)://\(openWRTUrl):\(server.openWRTPort ?? "80")"
        
        // print("🗑 开始删除配置文件: \(configFilename)")
        logger.info("开始删除配置文件: \(configFilename)")
        
        guard let username = server.openWRTUsername,
              let password = server.openWRTPassword else {
            // print("未找到认证信息")
            logger.error("未找到认证信息")
            throw NetworkError.unauthorized(message: "未设置 OpenWRT 用户名或密码")
        }
        
        // print("获取认证令牌...")
        // logger.info("获取认证令牌...")
        let token = try await getAuthToken(server, username: username, password: password)
        // print("获取令牌成功: \(token)")
        logger.info("获取令牌成功: \(token)")
        
        guard let url = URL(string: "\(baseURL)/cgi-bin/luci/rpc/sys?auth=\(token)") else {
            // print("无效的 URL")
            throw NetworkError.invalidURL
        }
        if packageName == "openclash" {
            let deleteCommand = """
            rm -f /tmp/Proxy_Group && \
            rm -f \"/etc/openclash/backup/\(configFilename)\" && \
            rm -f \"/etc/openclash/history/\(configFilename)\" && \
            rm -f \"/etc/openclash/history/\(configFilename).db\" && \
            rm -f \"/etc/openclash/\(configFilename)\" && \
            rm -f \"/etc/openclash/config/\(configFilename)\"
            """
            
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("sysauth=\(token); sysauth_http=\(token); sysauth_https=\(token)", forHTTPHeaderField: "Cookie")
            
            let command: [String: Any] = [
                "method": "exec",
                "params": [deleteCommand]
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: command)
            
            let session = makeURLSession(for: server)
            let (_, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse,
                httpResponse.statusCode == 200 else {
                // print("删除失败")
                logger.error("删除失败")
                throw NetworkError.serverError((response as? HTTPURLResponse)?.statusCode ?? 500)
            }
            
            // print("配置文件删除成功")
            logger.info("配置文件删除成功")
        } else {
            // mihomoTProxy
            
            // 检查是否使用 nikki
            let isNikki = try await isUsingNikki(server, token: token)
            let packagePrefix = isNikki ? "nikki" : "mihomo"
            
            let deleteCommand: String

            if isSubscription {
                // let removeCommand = "uci delete mihomo.\(configFilename.replacingOccurrences(of: ".yaml", with: "").replacingOccurrences(of: ".yml", with: "")) && uci commit mihomo"
                // let removeResponse = try await makeUCIRequest(server, token: token, method: "sys", params: ["exec", [removeCommand]])

                // logger.log("删除订阅配置响应: \(removeResponse)")
                deleteCommand = "rm '/etc/\(packagePrefix)/subscriptions/\(configFilename)'"
            } else {
                deleteCommand = "rm '/etc/\(packagePrefix)/profiles/\(configFilename)'"
            }

            // print("🗑 开始删除配置文件: \(deleteCommand)")

            let deleteResponse = try await makeUCIRequest(server, token: token, method: "sys", params: ["exec", [deleteCommand]])
            logger.info("删除配置文件响应: \(deleteResponse)")

        }
    }
    
    func fetchMihomoTProxyConfigs(_ server: ClashServer) async throws -> [OpenClashConfig] {
        logger.info("🔍 开始获取 Nikki 配置列表")
        // 获取认证 token
        guard let username = server.openWRTUsername,
              let password = server.openWRTPassword else {
            // print("未设置 OpenWRT 用户名或密码")
            throw NetworkError.unauthorized(message: "未设置 OpenWRT 用户名或密码")
        }
        
        // print("获取认证令牌...")
        let token = try await getAuthToken(server, username: username, password: password)
        // print("获取令牌成功")
        var configs: [OpenClashConfig] = []
        
        // 检查是否使用 nikki
        let isNikki = try await isUsingNikki(server, token: token)
        let packagePrefix = isNikki ? "nikki" : "mihomo"
        
        // 1. 获取 profiles 目录下的配置文件（非订阅）
        // print("📂 获取 profiles 目录下的配置文件...")
        let profilesResponse = try await makeUCIRequest(server, token: token, method: "fs", params: ["glob", ["/etc/\(packagePrefix)/profiles/*"]])
        // print("profiles 响应: \(profilesResponse)")
        
        if let result = profilesResponse["result"] as? [Any],
           let profiles = result.first as? [String] {
            logger.info("📝 找到 \(profiles.count) 个配置文件")
            for profile in profiles {
                // logger.log("处理配置文件: \(profile)")
                // 只处理 yaml 或 yml 文件
                guard profile.hasSuffix(".yaml") || profile.hasSuffix(".yml") else {
                    logger.info("⏭️ 跳过非 YAML 文件: \(profile)")
                    continue
                }
                
                // 获取文件元数据
                // print("获取文件元数据...")
                let metadata = try await makeUCIRequest(server, token: token, method: "fs", params: ["stat", [profile]])
                logger.info("文件元数据: \(metadata)")
                
                if let stat = metadata["result"] as? [String: Any] {
                    let name = profile.replacingOccurrences(of: "/etc/\(packagePrefix)/profiles/", with: "")
                    let mtime = Date(timeIntervalSince1970: (stat["mtime"] as? TimeInterval) ?? 0)
                    let size = Int64((stat["size"] as? Int) ?? 0)
                    
                    // print("📄 创建配置对象:")
                    // print("- 名称: \(name)")
                    // print("- 修改时间: \(mtime)")
                    // print("- 大小: \(size)")
                    
                    let config = OpenClashConfig(
                        name: name,
                        state: .disabled,  // 稍后更新状态
                        mtime: mtime,
                        check: .normal,    // MihomoTProxy 不支持语法检查
                        subscription: nil,
                        fileSize: size
                    )
                    var updatedConfig = config
                    updatedConfig.isSubscription = false
                    configs.append(updatedConfig)
                    // logger.log("添加配置成功")
                }
            }
        }
        
        // 2. 获取 subscriptions 目录下的配置文件（订阅）
        // print("\n📂 获取 subscriptions 目录下的配置文件...")
        let subscriptionsResponse = try await makeUCIRequest(server, token: token, method: "fs", params: ["glob", ["/etc/\(packagePrefix)/subscriptions/*"]])
        // print("subscriptions 响应: \(subscriptionsResponse)")
        
        if let result = subscriptionsResponse["result"] as? [Any],
           let subscriptions = result.first as? [String] {
            logger.info("📝 找到 \(subscriptions.count) 个订阅配置")
            for subscription in subscriptions {
                // print("处理订阅配置: \(subscription)")
                // 只处理 yaml 或 yml 文件
                guard subscription.hasSuffix(".yaml") || subscription.hasSuffix(".yml") else {
                    logger.info("⏭️ 跳过非 YAML 文件: \(subscription)")
                    continue
                }
                
                let subId = subscription.replacingOccurrences(of: "/etc/\(packagePrefix)/subscriptions/", with: "")
                
                // 获取订阅详情
                // print("获取订阅详情...")
                let detailResponse = try await makeUCIRequest(server, token: token, method: "sys", params: ["exec", ["uci show \(packagePrefix)." + subId.replacingOccurrences(of: ".yaml", with: "").replacingOccurrences(of: ".yml", with: "")]])
                // print("订阅详情响应: \(detailResponse)")
                
                if let detailResult = detailResponse["result"] as? String,
                   !detailResult.isEmpty {  // 只有在有订阅详情时才继续处理
                    // 获取文件元数据
                    // print("获取文件元数据...")
                    let metadata = try await makeUCIRequest(server, token: token, method: "fs", params: ["stat", [subscription]])
                    // print("文件元数据: \(metadata)")
                    
                    if let stat = metadata["result"] as? [String: Any] {
//                        let name = subId
                        let mtime = Date(timeIntervalSince1970: (stat["mtime"] as? TimeInterval) ?? 0)
                        let size = Int64((stat["size"] as? Int) ?? 0)
                        
                        // print("📄 创建订阅配置对象:")
                        // print("- 显示名: \(name)")
                        // print("- 修改时间: \(mtime)")
                        // print("- 大小: \(size)")
                        
                        // 解析订阅详情
                        var subscriptionInfo: OpenClashConfig.SubscriptionInfo? = nil
                        let lines = detailResult.split(separator: "\n")
                        var subData: [String: String] = [:]
                        for line in lines {
                            let parts = line.split(separator: "=", maxSplits: 1)
                            if parts.count == 2 {
                                let key = String(parts[0].split(separator: ".").last ?? "")
                                let value = String(parts[1]).trimmingCharacters(in: CharacterSet(charactersIn: "'"))
                                subData[key] = value
                                // print("订阅数据: \(key) = \(value)")
                            }
                        }
                        
                        // 计算剩余天数
                        var dayLeft: Int? = nil
                        if let expireStr = subData["expire"] {
                            let dateFormatter = DateFormatter()
                            dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                            if let expireDate = dateFormatter.date(from: expireStr) {
                                dayLeft = Calendar.current.dateComponents([.day], from: Date(), to: expireDate).day
                            }
                        }
                        
                        // 计算使用百分比
                        var percent: String? = nil
                        if let usedStr = subData["used"]?.replacingOccurrences(of: " GB", with: ""),
                           let totalStr = subData["total"]?.replacingOccurrences(of: " GB", with: ""),
                           let used = Double(usedStr),
                           let total = Double(totalStr) {
                            let percentage = (used / total) * 100
                            percent = String(format: "%.1f", percentage)
                        }
                        
                        // 格式化到期时间
                        var formattedExpire: String? = nil
                        if let expireStr = subData["expire"] {
                            let inputFormatter = DateFormatter()
                            inputFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                            let outputFormatter = DateFormatter()
                            outputFormatter.dateFormat = "yyyy-MM-dd"
                            if let date = inputFormatter.date(from: expireStr) {
                                formattedExpire = outputFormatter.string(from: date)
                            }
                        }
                        
                        subscriptionInfo = OpenClashConfig.SubscriptionInfo(
                            surplus: subData["avaliable"],
                            total: subData["total"],
                            dayLeft: dayLeft,
                            httpCode: nil,
                            used: subData["used"],
                            expire: formattedExpire,
                            subInfo: subData["url"] ?? "",
                            percent: percent
                        )
                        // print("创建订阅信息成功")
                        
                        // 创建并添加配置
                        let config = OpenClashConfig(
                            name: subData["name"] ?? subId,  // 使用订阅的 name 字段，如果没有则使用文件名
                            filename: subId,  // 使用原始文件名
                            state: .disabled,  // 稍后更新状态
                            mtime: mtime,
                            check: .normal,    // MihomoTProxy 不支持语法检查
                            subscription: subscriptionInfo,
                            fileSize: size
                        )
                        var updatedConfig = config
                        updatedConfig.isSubscription = true
                        configs.append(updatedConfig)
                        // print("添加订阅配置成功")
                    }
                }
            }
        }
        
        // 3. 获取当前使用的配置
        // print("\n🔍 获取当前使用的配置...")
        let currentConfigResponse = try await makeUCIRequest(server, token: token, method: "sys", params: ["exec", ["uci show \(packagePrefix).config.profile"]])
        // logger.log("当前配置响应: \(currentConfigResponse)")
        
        if let currentConfig = currentConfigResponse["result"] as? String,
           !currentConfig.isEmpty {  // 只在有结果时处理
            let currentConfigStr = currentConfig.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                                              .replacingOccurrences(of: "'", with: "")
            // print("📄 当前使用的配置: \(currentConfigStr)")
            
            // 解析配置字符串
            let parts = currentConfigStr.split(separator: ":")
            if parts.count == 2 {
                let configType = String(parts[0]).replacingOccurrences(of: "\(packagePrefix).config.profile=", with: "")  // subscription 或 file
                let configName = String(parts[1]) // 配置名称
                logger.info("配置类型: \(configType), 配置名称: \(configName)")
                
                // 更新配置状态
                configs = configs.map { config in
                    var updatedConfig = config
                    let isMatch = (configType == "subscription" && config.isSubscription && 
                                   config.filename.replacingOccurrences(of: ".yaml", with: "")
                                            .replacingOccurrences(of: ".yml", with: "") == configName) ||
                              (configType == "file" && !config.isSubscription && config.name == configName)
                    if isMatch {
                        updatedConfig.state = .enabled
                        // print("标记配置为启用状态: \(config.name)")
                    }
                    return updatedConfig
                }
            }
        }
        
        // print("\n最终配置列表:")
        // for config in configs {
        //     print("- \(config.name) (订阅: \(config.isSubscription), 状态: \(config.state))")
        // }
        
        return configs
    }
    
    private func makeUCIRequest(_ server: ClashServer, token: String, method: String, params: [Any]) async throws -> [String: Any] {
        let scheme = server.openWRTUseSSL ? "https" : "http"
        guard let openWRTUrl = server.openWRTUrl else {
            throw NetworkError.invalidURL
        }
        let baseURL = "\(scheme)://\(openWRTUrl):\(server.openWRTPort ?? "80")"
        
        guard let url = URL(string: "\(baseURL)/cgi-bin/luci/rpc/\(method)?auth=\(token)") else {
            throw NetworkError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("sysauth=\(token); sysauth_http=\(token); sysauth_https=\(token)", forHTTPHeaderField: "Cookie")
        
        let requestBody: [String: Any] = [
            "id": 1,
            "method": params[0],
            "params": params[1]
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        
        let session = makeURLSession(for: server)
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw NetworkError.serverError((response as? HTTPURLResponse)?.statusCode ?? 500)
        }
        
        guard let jsonResponse = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NetworkError.invalidResponse(message: "Invalid JSON response")
        }
        
        return jsonResponse
    }
    
    @MainActor
    func moveServer(from: Int, to: Int) {
        let item = servers.remove(at: from)
        servers.insert(item, at: to)
        saveServers()
    }

    // 添加一个公共方法来检查是否使用 nikki
    public func isUsingNikki(_ server: ClashServer, token: String) async throws -> Bool {
        let response = try await makeUCIRequest(server, token: token, method: "sys", params: ["exec", ["uci show nikki"]])
        
        // 检查 result 是否为空
        if let result = response["result"] as? String,
           !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            logger.debug("检测到使用 nikki 配置")
            return true
        }
        
        logger.debug("使用默认 MihomoTProxy 配置")
        return false
    }

    // 添加一个便捷方法，自动处理 token 获取
    public func checkIsUsingNikki(_ server: ClashServer) async throws -> Bool {
        guard let username = server.openWRTUsername,
              let password = server.openWRTPassword else {
            throw NetworkError.unauthorized(message: "未设置 OpenWRT 用户名或密码")
        }
        
        let token = try await getAuthToken(server, username: username, password: password)
        return try await isUsingNikki(server, token: token)
    }
    
    // 添加上传配置文件的方法
    func uploadConfigFile(_ server: ClashServer, fileData: Data, fileName: String, packageName: String) async throws {
        let scheme = server.openWRTUseSSL ? "https" : "http"
        guard let openWRTUrl = server.openWRTUrl else {
            throw NetworkError.invalidURL
        }
        let baseURL = "\(scheme)://\(openWRTUrl):\(server.openWRTPort ?? "80")"
        
        logger.info("开始上传配置文件: \(fileName)")
        
        // 获取认证信息
        guard let username = server.openWRTUsername,
              let password = server.openWRTPassword else {
            logger.error("未找到认证信息")
            throw NetworkError.unauthorized(message: "未设置 OpenWRT 用户名或密码")
        }
        
        // 获取认证 token
        let token = try await getAuthToken(server, username: username, password: password)
        
        if packageName == "openclash" {
            // OpenClash 使用不同的上传API
            try await uploadOpenClashConfig(server, token: token, fileData: fileData, fileName: fileName, baseURL: baseURL)
        } else {
            // MihomoTProxy 使用 cgi-upload
            try await uploadMihomoConfig(server, token: token, fileData: fileData, fileName: fileName, baseURL: baseURL)
        }
    }
    
    // OpenClash 上传方法
    private func uploadOpenClashConfig(_ server: ClashServer, token: String, fileData: Data, fileName: String, baseURL: String) async throws {
        // 1. 首先获取配置页面以提取动态 token
        guard let configPageURL = URL(string: "\(baseURL)/cgi-bin/luci/admin/services/openclash/config") else {
            throw NetworkError.invalidURL
        }
        
        logger.info("OpenClash 获取配置页面: \(configPageURL)")
        
        // 创建获取配置页面的请求
        var pageRequest = URLRequest(url: configPageURL)
        pageRequest.httpMethod = "GET"
        pageRequest.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7", forHTTPHeaderField: "Accept")
        pageRequest.setValue("en-US,en;q=0.9,zh-CN;q=0.8,zh-TW;q=0.7,zh;q=0.6", forHTTPHeaderField: "Accept-Language")
        pageRequest.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        pageRequest.setValue("keep-alive", forHTTPHeaderField: "Connection")
        pageRequest.setValue("1", forHTTPHeaderField: "DNT")
        pageRequest.setValue("no-cache", forHTTPHeaderField: "Pragma")
        pageRequest.setValue("document", forHTTPHeaderField: "Sec-Fetch-Dest")
        pageRequest.setValue("navigate", forHTTPHeaderField: "Sec-Fetch-Mode")
        pageRequest.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        pageRequest.setValue("?1", forHTTPHeaderField: "Sec-Fetch-User")
        pageRequest.setValue("1", forHTTPHeaderField: "Upgrade-Insecure-Requests")
        pageRequest.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        
        // 设置 Cookie
        let cookieName = server.openWRTUseSSL ? "sysauth_https" : "sysauth_http"
        pageRequest.setValue("\(cookieName)=\(token)", forHTTPHeaderField: "Cookie")
        
        let session = makeURLSession(for: server)
        let (pageData, pageResponse) = try await session.data(for: pageRequest)
        
        guard let httpPageResponse = pageResponse as? HTTPURLResponse,
              httpPageResponse.statusCode == 200 else {
            logger.error("获取配置页面失败")
            throw NetworkError.serverError((pageResponse as? HTTPURLResponse)?.statusCode ?? 500)
        }
        
        // 2. 解析 HTML 内容，提取动态 token
        guard let htmlContent = String(data: pageData, encoding: .utf8) else {
            logger.error("无法解析 HTML 内容")
            throw NetworkError.invalidResponse(message: "无法解析 HTML 内容")
        }
        
        logger.debug("获取到 HTML 内容长度: \(htmlContent.count)")
        
        // 提取 JavaScript 中的 token
        let dynamicToken = try extractTokenFromHTML(htmlContent)
        logger.info("提取到动态 token: \(dynamicToken)")
        
        // 3. 使用动态 token 进行上传
        guard let uploadURL = URL(string: "\(baseURL)/cgi-bin/luci/admin/services/openclash/config") else {
            throw NetworkError.invalidURL
        }
        
        logger.info("OpenClash 开始上传到: \(uploadURL)")
        
        // 创建 multipart/form-data 请求
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        
        // 生成边界字符串
        let boundary = "----WebKitFormBoundary\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        // 设置 Cookie
        request.setValue("\(cookieName)=\(token)", forHTTPHeaderField: "Cookie")
        
        // 构建 multipart 数据
        var body = Data()
        
        // 添加动态 token 字段
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"token\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(dynamicToken)\r\n".data(using: .utf8)!)
        
        // 添加 cbi.submit 字段
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"cbi.submit\"\r\n\r\n".data(using: .utf8)!)
        body.append("1\r\n".data(using: .utf8)!)
        
        // 添加 file_type 字段
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file_type\"\r\n\r\n".data(using: .utf8)!)
        body.append("config\r\n".data(using: .utf8)!)
        
        // 添加 ulfile 字段（文件数据）
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"ulfile\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/x-yaml\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)
        
        // 添加 upload 字段
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"upload\"\r\n\r\n".data(using: .utf8)!)
        body.append("上传\r\n".data(using: .utf8)!)
        
        // 结束边界
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        
        request.httpBody = body
        
        // 发送请求
        let (_, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("无效的响应类型")
            throw NetworkError.invalidResponse(message: "无效的响应类型")
        }
        
        logger.info("OpenClash 上传响应状态码: \(httpResponse.statusCode)")
        
        // if let responseData = String(data: data, encoding: .utf8) {
        //     logger.info("OpenClash 上传响应内容: \(responseData)")
        // }
        
        switch httpResponse.statusCode {
        case 200:
            logger.info("OpenClash 配置文件上传成功")
        case 401:
            logger.error("认证失败")
            throw NetworkError.unauthorized(message: "认证失败，请检查用户名和密码")
        case 413:
            logger.error("文件过大")
            throw NetworkError.invalidResponse(message: "文件过大，无法上传")
        case 415:
            logger.error("不支持的文件类型")
            throw NetworkError.invalidResponse(message: "不支持的文件类型")
        default:
            logger.error("OpenClash 上传失败，状态码: \(httpResponse.statusCode)")
            throw NetworkError.serverError(httpResponse.statusCode)
        }
    }
    
    // 从 HTML 内容中提取动态 token
    private func extractTokenFromHTML(_ htmlContent: String) throws -> String {
        logger.debug("🔍 开始提取动态 token")
        
        // 查找包含 LuCI 初始化的 script 标签
        let patterns = [
            #""token":\s*"([^"]+)""#,  // 匹配 "token": "value"
            #"token":\s*"([^"]+)""#,   // 匹配 token: "value"
            #""token"\s*:\s*"([^"]+)""# // 另一种匹配方式
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let range = NSRange(location: 0, length: htmlContent.count)
                if let match = regex.firstMatch(in: htmlContent, options: [], range: range) {
                    if let tokenRange = Range(match.range(at: 1), in: htmlContent) {
                        let token = String(htmlContent[tokenRange])
                        logger.debug("成功提取到 token: \(token)")
                        return token
                    }
                }
            }
        }
        
        // 如果正则表达式失败，尝试更简单的字符串查找
        logger.debug("正则表达式提取失败，尝试字符串查找")
        
        // 查找 "token": " 开始的位置
        if let tokenStart = htmlContent.range(of: "\"token\": \"") {
            let afterToken = htmlContent[tokenStart.upperBound...]
            if let tokenEnd = afterToken.range(of: "\"") {
                let token = String(afterToken[..<tokenEnd.lowerBound])
                logger.debug("字符串查找成功提取到 token: \(token)")
                return token
            }
        }
        
        // 再尝试不带引号的版本
        if let tokenStart = htmlContent.range(of: "token: \"") {
            let afterToken = htmlContent[tokenStart.upperBound...]
            if let tokenEnd = afterToken.range(of: "\"") {
                let token = String(afterToken[..<tokenEnd.lowerBound])
                logger.debug("备用字符串查找成功提取到 token: \(token)")
                return token
            }
        }
        
        logger.error("无法从 HTML 中提取 token")
        // logger.debug("HTML 内容片段: \(String(htmlContent.prefix(500)))")
        throw NetworkError.invalidResponse(message: "无法从页面中提取动态 token")
    }
    
    // MihomoTProxy 上传方法
    private func uploadMihomoConfig(_ server: ClashServer, token: String, fileData: Data, fileName: String, baseURL: String) async throws {
        // 检查是否使用 nikki
        let isNikki = try await isUsingNikki(server, token: token)
        let packagePrefix = isNikki ? "nikki" : "mihomo"
        let targetPath = "/etc/\(packagePrefix)/profiles/\(fileName)"
        
        logger.info("MihomoTProxy 上传目标路径: \(targetPath)")
        
        // 构建上传 URL
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        guard let uploadURL = URL(string: "\(baseURL)/cgi-bin/cgi-upload?\(timestamp)") else {
            throw NetworkError.invalidURL
        }
        
        // 创建 multipart/form-data 请求
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        
        // 生成边界字符串
        let boundary = "----WebKitFormBoundary\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        // 构建 multipart 数据
        var body = Data()
        
        // 添加 sessionid 字段
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"sessionid\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(token)\r\n".data(using: .utf8)!)
        
        // 添加 filename 字段
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"filename\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(targetPath)\r\n".data(using: .utf8)!)
        
        // 添加 filedata 字段
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"filedata\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/x-yaml\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)
        
        // 结束边界
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        
        request.httpBody = body
        
        // 发送请求
        let session = makeURLSession(for: server)
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("无效的响应类型")
            throw NetworkError.invalidResponse(message: "无效的响应类型")
        }
        
        logger.info("MihomoTProxy 上传响应状态码: \(httpResponse.statusCode)")
        
        if let responseData = String(data: data, encoding: .utf8) {
            logger.info("MihomoTProxy 上传响应内容: \(responseData)")
        }
        
        switch httpResponse.statusCode {
        case 200:
            logger.info("MihomoTProxy 配置文件上传成功")
        case 401:
            logger.error("认证失败")
            throw NetworkError.unauthorized(message: "认证失败，请检查用户名和密码")
        case 413:
            logger.error("文件过大")
            throw NetworkError.invalidResponse(message: "文件过大，无法上传")
        case 415:
            logger.error("不支持的文件类型")
            throw NetworkError.invalidResponse(message: "不支持的文件类型")
        default:
            logger.error("MihomoTProxy 上传失败，状态码: \(httpResponse.statusCode)")
            throw NetworkError.serverError(httpResponse.statusCode)
        }
    }
} 
