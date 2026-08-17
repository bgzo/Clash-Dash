import SwiftUI
import CoreHaptics
import CoreLocation
import CloudKit

struct DualSlider: View {
    @Binding var lowValue: Double
    @Binding var highValue: Double
    let range: ClosedRange<Double>
    let step: Double
    let lowColor: Color
    let highColor: Color
    
    private var trackWidth: CGFloat {
        let width = UIScreen.main.bounds.width - 40 // Form 的左右边距
        return width
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // 背景轨道
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(.systemGray5))
                    .frame(height: 4)
                
                // 低延迟区域（绿色到黄色）
                RoundedRectangle(cornerRadius: 2)
                    .fill(LinearGradient(
                        colors: [DelayColor.low, DelayColor.medium],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    .frame(width: max(0, lowValue - range.lowerBound) / (range.upperBound - range.lowerBound) * geometry.size.width,
                           height: 4)
                
                // 中延迟区域（黄色到橙色）
                RoundedRectangle(cornerRadius: 2)
                    .fill(LinearGradient(
                        colors: [DelayColor.medium, DelayColor.high],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    .frame(width: max(0, highValue - lowValue) / (range.upperBound - range.lowerBound) * geometry.size.width,
                           height: 4)
                    .offset(x: max(0, lowValue - range.lowerBound) / (range.upperBound - range.lowerBound) * geometry.size.width)
                
                // 高延迟区域（橙色到红色）
                RoundedRectangle(cornerRadius: 2)
                    .fill(LinearGradient(
                        colors: [DelayColor.high, .red],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    .frame(width: max(0, range.upperBound - highValue) / (range.upperBound - range.lowerBound) * geometry.size.width,
                           height: 4)
                    .offset(x: max(0, highValue - range.lowerBound) / (range.upperBound - range.lowerBound) * geometry.size.width)
                
                // 低值滑块
                Circle()
                    .fill(.white)
                    .shadow(radius: 1)
                    .frame(width: 24, height: 24)
                    .offset(x: max(0, lowValue - range.lowerBound) / (range.upperBound - range.lowerBound) * (geometry.size.width - 24))
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let ratio = value.location.x / geometry.size.width
                                var newValue = range.lowerBound + (range.upperBound - range.lowerBound) * ratio
                                // 应用步进值
                                newValue = (newValue / step).rounded() * step
                                // 确保在范围内且不超过高值
                                lowValue = min(max(newValue, range.lowerBound), highValue - step)
                            }
                    )
                
                // 高值滑块
                Circle()
                    .fill(.white)
                    .shadow(radius: 1)
                    .frame(width: 24, height: 24)
                    .offset(x: max(0, highValue - range.lowerBound) / (range.upperBound - range.lowerBound) * (geometry.size.width - 24))
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let ratio = value.location.x / geometry.size.width
                                var newValue = range.lowerBound + (range.upperBound - range.lowerBound) * ratio
                                // 应用步进值
                                newValue = (newValue / step).rounded() * step
                                // 确保在范围内且不小于低值
                                highValue = max(min(newValue, range.upperBound), lowValue + step)
                            }
                    )
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 44)
    }
}

struct GlobalSettingsView: View {
    @AppStorage("autoDisconnectOldProxy") private var autoDisconnectOldProxy = false
    @AppStorage("hideUnavailableProxies") private var hideUnavailableProxies = false
    @AppStorage("proxyGroupSortOrder") private var proxyGroupSortOrder = ProxyGroupSortOrder.default
    @AppStorage("speedTestURL") private var speedTestURL = "https://www.gstatic.com/generate_204"
    @AppStorage("speedTestTimeout") private var speedTestTimeout = 5000
    @AppStorage("pinBuiltinProxies") private var pinBuiltinProxies = false
    @AppStorage("hideProxyProviders") private var hideProxyProviders = false
    @AppStorage("smartProxyGroupDisplay") private var smartProxyGroupDisplay = false
    @AppStorage("enableCloudSync") private var enableCloudSync = false
    @AppStorage("autoSpeedTestBeforeSwitch") private var autoSpeedTestBeforeSwitch = true
    @AppStorage("allowManualURLTestGroupSwitch") private var allowManualURLTestGroupSwitch = false
    @AppStorage("serverStatusTimeout") private var serverStatusTimeout = 2.0  // 默认2秒
    @State private var showClearCacheAlert = false
    @State private var cloudKitManager: CloudKitManager?
    
    var body: some View {
        Form {
            Section {
                SettingToggleRow(
                    title: "自动断开旧连接",
                    subtitle: "切换代理时自动断开旧的连接",
                    isOn: $autoDisconnectOldProxy
                )
                
                SettingToggleRow(
                    title: "切换前自动测速",
                    subtitle: "在切换到新的代理节点前获取最新延迟",
                    isOn: $autoSpeedTestBeforeSwitch
                )
                
                SettingToggleRow(
                    title: "允许手动切换自动测速组",
                    subtitle: "允许手动切换自动测速选择分组的节点",
                    isOn: $allowManualURLTestGroupSwitch
                )
            } header: {
                SectionHeader(title: "切换代理设置", systemImage: "network")
            }
            
            Section {
                SettingToggleRow(
                    title: "隐藏不可用代理",
                    subtitle: "在代理组的代理节点列表中不显示无法连接的代理",
                    isOn: $hideUnavailableProxies
                )
                
                NavigationLink {
                    ProxyGroupSortOrderView(selection: $proxyGroupSortOrder)
                } label: {
                    SettingRow(
                        title: "排序方式",
                        value: proxyGroupSortOrder.description
                    )
                }
                
                SettingToggleRow(
                    title: "置顶内置策略",
                    subtitle: "将 DIRECT 和 REJECT 等内置策略始终保持在最前面",
                    isOn: $pinBuiltinProxies
                )
                
                SettingToggleRow(
                    title: "隐藏代理提供者",
                    subtitle: "在代理页面中不显示代理提供者信息",
                    isOn: $hideProxyProviders
                )

                SettingToggleRow(
                    title: "Global 代理组显示控制",
                    subtitle: "规则/直连模式下隐藏 GLOBAL 组，全局模式下仅显示 GLOBAL 组",
                    isOn: $smartProxyGroupDisplay
                )
            } header: {
                SectionHeader(title: "代理组排序设置", systemImage: "arrow.up.arrow.down")
            }
            
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "link")
                            .foregroundColor(.secondary)
                        TextField("测速链接", text: $speedTestURL)
                            .textFieldStyle(.plain)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    .padding(12)
                    .background(Color(.systemGray6))
                    .cornerRadius(10)
                    
                    Text("用于测试代理延迟的URL地址")
                        .caption()
                }
                .padding(.vertical, 4)
                
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("超时时间")
                        Spacer()
                        Text("\(speedTestTimeout) ms")
                            .monospacedDigit()
                        Stepper("", value: $speedTestTimeout, in: 1000...10000, step: 500)
                            .labelsHidden()
                            .frame(width: 100)
                            .onChange(of: speedTestTimeout) { _ in
                                HapticManager.shared.impact(.light)
                            }
                    }
                    
                    Text("测速请求的最大等待时间")
                        .caption()
                }
            } header: {
                SectionHeader(title: "测速设置", systemImage: "speedometer")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("状态检查超时")
                        Spacer()
                        Text(String(format: "%.1f 秒", serverStatusTimeout))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    
                    Slider(
                        value: $serverStatusTimeout,
                        in: 0.5...10.0,
                        step: 0.5
                    )
                    .onChange(of: serverStatusTimeout) { _ in
                        HapticManager.shared.impact(.light)
                    }
                    
                    Text("检查服务器状态时的最大等待时间")
                        .caption()
                }
            } header: {
                SectionHeader(title: "控制器状态检查设置", systemImage: "timer")
            }
            
            Section {
                Button {
                    showClearCacheAlert = true
                } label: {
                    HStack {
                        Label("清除图标缓存", systemImage: "photo")
                        Spacer()
                        Text("已缓存 \(ImageCache.shared.count) 张图标")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                SectionHeader(title: "缓存管理", systemImage: "internaldrive")
            }
            
            Section {
                SettingToggleRow(
                    title: "启用 iCloud 同步",
                    subtitle: "同步服务器配置、全局设置和外观设置到 iCloud",
                    isOn: $enableCloudSync
                )
                
                if enableCloudSync, let cloudKitManager = cloudKitManager {
                    ICloudSyncSection(cloudKitManager: cloudKitManager)
                }
            } header: {
                SectionHeader(title: "iCloud 同步", systemImage: "icloud")
            } footer: {
                if enableCloudSync {
                    Text("上次同步时间：\(cloudKitManager?.lastSyncTime?.formatted() ?? "从未同步")")
                }
            }
            
            
        }
        .navigationTitle("全局配置")
        .navigationBarTitleDisplayMode(.inline)
        .alert("清除图标缓存", isPresented: $showClearCacheAlert) {
            Button("取消", role: .cancel) { }
            Button("清除", role: .destructive) {
                ImageCache.shared.removeAll()
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.success)
            }
        } message: {
            Text("确定要清除所有已缓存的图标吗？")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SettingsUpdated"))) { _ in
            // 强制视图刷新
            withAnimation {
                let impact = UIImpactFeedbackGenerator(style: .medium)
                impact.impactOccurred()
            }
        }
        .task {
            guard enableCloudSync else { return }
            if cloudKitManager == nil {
                cloudKitManager = CloudKitManager.shared
            }
            await cloudKitManager?.checkICloudStatus()
        }
        .onChange(of: enableCloudSync) { newValue in
            guard newValue else { return }
            if cloudKitManager == nil {
                cloudKitManager = CloudKitManager.shared
            }
            Task {
                await cloudKitManager?.checkICloudStatus()
            }
        }
    }
}

#Preview {
    NavigationStack {
        GlobalSettingsView()
    }
}

// MARK: - iCloud 同步子视图
// 使用 @ObservedObject 观察 CloudKitManager 的发布属性，仅在用户开启同步时创建
private struct ICloudSyncSection: View {
    @ObservedObject var cloudKitManager: CloudKitManager
    @State private var showSyncErrorAlert = false
    @State private var syncErrorMessage = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("iCloud 状态")
                Spacer()
                Text(cloudKitManager.iCloudStatus)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            
            SettingToggleRow(
                title: "同步全局设置",
                subtitle: "同步代理切换、排序、测速等全局设置",
                isOn: Binding(
                    get: { cloudKitManager.syncGlobalSettings },
                    set: { cloudKitManager.setSyncOption(globalSettings: $0) }
                )
            )
            
            SettingToggleRow(
                title: "同步控制器列表",
                subtitle: "同步所有控制器配置信息",
                isOn: Binding(
                    get: { cloudKitManager.syncServers },
                    set: { cloudKitManager.setSyncOption(servers: $0) }
                )
            )
            
            SettingToggleRow(
                title: "同步外观设置",
                subtitle: "同步主题、卡片样式等外观设置",
                isOn: Binding(
                    get: { cloudKitManager.syncAppearance },
                    set: { cloudKitManager.setSyncOption(appearance: $0) }
                )
            )
            
            Button {
                Task {
                    do {
                        try await cloudKitManager.syncToCloud()
                    } catch {
                        syncErrorMessage = error.localizedDescription
                        showSyncErrorAlert = true
                    }
                }
            } label: {
                HStack {
                    Label("立即同步到 iCloud", systemImage: "arrow.clockwise.icloud")
                    Spacer()
                    if cloudKitManager.isUploadingSyncing {
                        ProgressView()
                    }
                }
            }
            .disabled(cloudKitManager.isUploadingSyncing || cloudKitManager.isDownloadingSyncing || cloudKitManager.iCloudStatus != "可用")
            
            Button {
                Task {
                    do {
                        try await cloudKitManager.syncFromCloud()
                    } catch {
                        syncErrorMessage = error.localizedDescription
                        showSyncErrorAlert = true
                    }
                }
            } label: {
                HStack {
                    Label("从 iCloud 恢复", systemImage: "icloud.and.arrow.down")
                    Spacer()
                    if cloudKitManager.isDownloadingSyncing {
                        ProgressView()
                    }
                }
            }
            .disabled(cloudKitManager.isUploadingSyncing || cloudKitManager.isDownloadingSyncing || cloudKitManager.iCloudStatus != "可用")
        }
        .alert("同步错误", isPresented: $showSyncErrorAlert) {
            Button("确定", role: .cancel) { }
        } message: {
            Text(syncErrorMessage)
        }
    }
} 
