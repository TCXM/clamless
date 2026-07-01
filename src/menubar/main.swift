import Cocoa
import Foundation
import IOKit
import ServiceManagement

enum LayoutState: Equatable {
    case connected
    case disconnected
    case unknown
}

struct DisplayStatus {
    let layout: LayoutState
    let online: Bool?
    let mirror: Bool?
    let activeExternalCount: Int?
    let physicalExternalCount: Int?
    let hardwareExternalKeys: Set<String>?
    let lastHardwareUnplugEvent: UInt64?
    let lastHardwarePlugEvent: UInt64?
    let rawText: String

    var needsOffRepair: Bool {
        layout == .disconnected && mirror == true
    }
}

struct HelperResult {
    let exitCode: Int32
    let output: String
    let error: String

    var combinedText: String {
        [output, error]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

struct LocalizedText {
    private func value(_ key: String) -> String {
        NSLocalizedString(key, bundle: .main, comment: "")
    }

    var quit: String {
        value("quit")
    }

    var helperMissingTitle: String {
        value("helper_missing_title")
    }

    var helperMissingMessage: String {
        value("helper_missing_message")
    }

    var unknownStatusTitle: String {
        value("unknown_status_title")
    }

    var unknownStatusMessage: String {
        value("unknown_status_message")
    }

    var noMoreInfo: String {
        value("no_more_info")
    }

    var ok: String {
        value("ok")
    }

    var settings: String {
        value("settings")
    }

    var settingsTitle: String {
        value("settings_title")
    }

    var autoSwitchEnabled: String {
        value("auto_switch_enabled")
    }

    var openAtLogin: String {
        value("open_at_login")
    }

    var loginItemRequiresApproval: String {
        value("login_item_requires_approval")
    }

    var openLoginItemsSettings: String {
        value("open_login_items_settings")
    }

    var loginItemErrorTitle: String {
        value("login_item_error_title")
    }

    var noExternalDisplays: String {
        value("no_external_displays")
    }

    var close: String {
        value("close")
    }

    func statusTitle(status: DisplayStatus, isBusy: Bool, helperAvailable: Bool) -> String {
        if isBusy {
            return value("status_busy")
        }

        guard helperAvailable else {
            return value("status_helper_missing")
        }

        if status.needsOffRepair {
            return value("status_needs_off_repair")
        }

        switch status.layout {
        case .connected: return value("status_connected")
        case .disconnected: return value("status_disconnected")
        case .unknown: return value("status_unknown")
        }
    }

    func toggleTitle(status: DisplayStatus, externalCount: Int, helperAvailable: Bool, isBusy: Bool) -> String {
        if isBusy {
            return value("toggle_busy")
        }

        guard helperAvailable else {
            return value("toggle_helper_missing")
        }

        if status.needsOffRepair {
            return value("toggle_needs_off_repair")
        }

        switch status.layout {
        case .connected:
            return externalCount > 0 ? value("toggle_connected") : value("toggle_connected_no_external")
        case .disconnected:
            return value("toggle_disconnected")
        case .unknown:
            return value("toggle_unknown")
        }
    }

    func actionName(layout: LayoutState) -> String {
        switch layout {
        case .connected: return value("action_connected")
        case .disconnected: return value("action_disconnected")
        case .unknown: return value("action_unknown")
        }
    }

    func failureTitle(for action: String) -> String {
        String(format: value("failure_title_format"), action)
    }
}

final class AutoSwitchSettings {
    static let shared = AutoSwitchSettings()

    private let defaults = UserDefaults.standard
    private let autoEnabledKey = "autoSwitchEnabled"
    private let allowedDisplaysKey = "autoSwitchAllowedDisplayKeys"
    private let autoManagedOffKey = "autoSwitchManagedOff"
    private let legacyDefaultsDomain = "local.openlid.menu"
    private let migrationKey = "migratedFromOpenLidDefaults"

    private init() {
        migrateLegacyDefaultsIfNeeded()
    }

    var autoEnabled: Bool {
        get {
            if defaults.object(forKey: autoEnabledKey) == nil {
                return true
            }
            return defaults.bool(forKey: autoEnabledKey)
        }
        set {
            defaults.set(newValue, forKey: autoEnabledKey)
        }
    }

    var allowedDisplayKeys: Set<String> {
        get {
            Set(defaults.stringArray(forKey: allowedDisplaysKey) ?? [])
        }
        set {
            defaults.set(Array(newValue).sorted(), forKey: allowedDisplaysKey)
        }
    }

    var autoManagedOff: Bool {
        get {
            defaults.bool(forKey: autoManagedOffKey)
        }
        set {
            defaults.set(newValue, forKey: autoManagedOffKey)
        }
    }

    private func migrateLegacyDefaultsIfNeeded() {
        guard !defaults.bool(forKey: migrationKey) else { return }
        guard let legacyDomain = defaults.persistentDomain(forName: legacyDefaultsDomain) else {
            defaults.set(true, forKey: migrationKey)
            return
        }

        copyLegacyBool(autoEnabledKey, from: legacyDomain)
        copyLegacyStringArray(allowedDisplaysKey, from: legacyDomain)
        copyLegacyBool(autoManagedOffKey, from: legacyDomain)
        defaults.set(true, forKey: migrationKey)
    }

    private func copyLegacyBool(_ key: String, from legacyDomain: [String: Any]) {
        guard defaults.object(forKey: key) == nil else { return }

        if let value = legacyDomain[key] as? Bool {
            defaults.set(value, forKey: key)
        } else if let value = legacyDomain[key] as? NSNumber {
            defaults.set(value.boolValue, forKey: key)
        }
    }

    private func copyLegacyStringArray(_ key: String, from legacyDomain: [String: Any]) {
        guard defaults.object(forKey: key) == nil else { return }

        if let value = legacyDomain[key] as? [String] {
            defaults.set(value, forKey: key)
        } else if let value = legacyDomain[key] as? NSArray {
            defaults.set(value.compactMap { $0 as? String }, forKey: key)
        }
    }
}

enum LoginItemManager {
    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    static var isEnabled: Bool {
        status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            guard status != .enabled else { return }
            try SMAppService.mainApp.register()
        } else {
            guard status != .notRegistered, status != .notFound else { return }
            try SMAppService.mainApp.unregister()
        }
    }

    static func statusDescription(_ status: SMAppService.Status = SMAppService.mainApp.status) -> String {
        switch status {
        case .notRegistered, .notFound:
            return "disabled"
        case .enabled:
            return "enabled"
        case .requiresApproval:
            return "requires_approval"
        @unknown default:
            return "unknown"
        }
    }

    static func runCommandIfRequested(_ arguments: [String]) -> Bool {
        guard let command = arguments.dropFirst().first else {
            return false
        }

        do {
            switch command {
            case "--register-login-item":
                try setEnabled(true)
                print("login item: \(statusDescription())")
                return true
            case "--unregister-login-item":
                try setEnabled(false)
                print("login item: \(statusDescription())")
                return true
            case "--login-item-status":
                print("login item: \(statusDescription())")
                return true
            default:
                return false
            }
        } catch {
            fputs("login item failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}

struct ExternalDisplayInfo {
    let id: CGDirectDisplayID
    let key: String
    let name: String
}

enum DisplayInventory {
    static func activeExternalDisplays() -> [ExternalDisplayInfo] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return []
        }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else {
            return []
        }

        return displays
            .prefix(Int(count))
            .filter { CGDisplayIsBuiltin($0) == 0 }
            .map {
                ExternalDisplayInfo(
                    id: $0,
                    key: stableKey(for: $0),
                    name: displayName(for: $0)
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func stableKey(for display: CGDirectDisplayID) -> String {
        let vendor = CGDisplayVendorNumber(display)
        let model = CGDisplayModelNumber(display)
        let serial = CGDisplaySerialNumber(display)
        return "cgdisplay:\(vendor):\(model):\(serial)"
    }

    private static func displayName(for display: CGDirectDisplayID) -> String {
        if let screen = NSScreen.screens.first(where: { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return number.uint32Value == display
        }) {
            return screen.localizedName
        }

        let vendor = CGDisplayVendorNumber(display)
        let model = CGDisplayModelNumber(display)
        return "Display \(vendor)-\(model)"
    }
}

final class SettingsWindowController: NSWindowController {
    private let text = LocalizedText()
    private let settings = AutoSwitchSettings.shared
    private let onChange: () -> Void
    private let stack = NSStackView()

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = text.settingsTitle
        window.isReleasedWhenClosed = false
        super.init(window: window)
        configureContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        rebuild()
        super.showWindow(sender)
        window?.center()
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func configureContent() {
        guard let contentView = window?.contentView else { return }
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor)
        ])
    }

    private func rebuild() {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let enable = NSButton(checkboxWithTitle: text.autoSwitchEnabled, target: self, action: #selector(toggleAutoSwitch(_:)))
        enable.state = settings.autoEnabled ? .on : .off
        stack.addArrangedSubview(enable)

        let openAtLogin = NSButton(checkboxWithTitle: text.openAtLogin, target: self, action: #selector(toggleOpenAtLogin(_:)))
        openAtLogin.state = LoginItemManager.isEnabled ? .on : .off
        stack.addArrangedSubview(openAtLogin)

        if LoginItemManager.status == .requiresApproval {
            let approvalStack = NSStackView()
            approvalStack.orientation = .horizontal
            approvalStack.alignment = .centerY
            approvalStack.spacing = 8

            let label = NSTextField(labelWithString: text.loginItemRequiresApproval)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 2

            let button = NSButton(title: text.openLoginItemsSettings, target: self, action: #selector(openLoginItemsSettings))
            button.bezelStyle = .rounded

            approvalStack.addArrangedSubview(label)
            approvalStack.addArrangedSubview(button)
            stack.addArrangedSubview(approvalStack)
        }

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.widthAnchor.constraint(equalToConstant: 388).isActive = true
        stack.addArrangedSubview(separator)

        let displays = DisplayInventory.activeExternalDisplays()
        if displays.isEmpty {
            let label = NSTextField(labelWithString: text.noExternalDisplays)
            label.textColor = .secondaryLabelColor
            stack.addArrangedSubview(label)
        } else {
            let allowed = settings.allowedDisplayKeys
            for display in displays {
                let checkbox = NSButton(checkboxWithTitle: display.name, target: self, action: #selector(toggleDisplay(_:)))
                checkbox.identifier = NSUserInterfaceItemIdentifier(display.key)
                checkbox.toolTip = display.key
                checkbox.state = allowed.contains(display.key) ? .on : .off
                stack.addArrangedSubview(checkbox)
            }
        }

        let closeButton = NSButton(title: text.close, target: self, action: #selector(closeWindow))
        closeButton.bezelStyle = .rounded
        stack.addArrangedSubview(closeButton)
    }

    @objc private func toggleAutoSwitch(_ sender: NSButton) {
        settings.autoEnabled = sender.state == .on
        onChange()
    }

    @objc private func toggleOpenAtLogin(_ sender: NSButton) {
        do {
            try LoginItemManager.setEnabled(sender.state == .on)
        } catch {
            sender.state = LoginItemManager.isEnabled ? .on : .off
            showLoginItemError(error)
        }
        rebuild()
    }

    @objc private func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    @objc private func toggleDisplay(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        var allowed = settings.allowedDisplayKeys
        if sender.state == .on {
            allowed.insert(key)
        } else {
            allowed.remove(key)
        }
        settings.allowedDisplayKeys = allowed
        onChange()
    }

    @objc private func closeWindow() {
        window?.close()
    }

    private func showLoginItemError(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = text.loginItemErrorTitle
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: text.ok)
        if LoginItemManager.status == .requiresApproval {
            alert.addButton(withTitle: text.openLoginItemsSettings)
        }
        if alert.runModal() == .alertSecondButtonReturn {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}

final class ClamlessHelper {
    let executableURL: URL

    init?() {
        if let bundled = Bundle.main.url(forResource: "clamless-display", withExtension: nil),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            executableURL = bundled
            return
        }

        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        let sibling = executable.deletingLastPathComponent().appendingPathComponent("clamless-display")
        if FileManager.default.isExecutableFile(atPath: sibling.path) {
            executableURL = sibling
            return
        }

        return nil
    }

    func run(_ arguments: [String]) -> HelperResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return HelperResult(exitCode: 127, output: "", error: error.localizedDescription)
        }

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        return HelperResult(
            exitCode: process.terminationStatus,
            output: String(data: outData, encoding: .utf8) ?? "",
            error: String(data: errData, encoding: .utf8) ?? ""
        )
    }
}

final class DisplayConnectionObserver {
    private var notificationPort: IONotificationPortRef?
    private var notifiers = [io_object_t]()
    private let onChange: () -> Void

    init?(onChange: @escaping () -> Void) {
        self.onChange = onChange

        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            return nil
        }
        notificationPort = port

        if let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, CFRunLoopMode.commonModes)
        }

        addInterestNotifications(for: "AppleATCDPAltModePort", port: port)
        addInterestNotifications(for: "AppleDisplayConnectionManager", port: port)

        if notifiers.isEmpty {
            IONotificationPortDestroy(port)
            notificationPort = nil
            return nil
        }
    }

    private func addInterestNotifications(for className: String, port: IONotificationPortRef) {
        guard let match = IOServiceMatching(className) else {
            return
        }

        var iter: io_iterator_t = IO_OBJECT_NULL
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter) == KERN_SUCCESS else {
            return
        }
        defer {
            IOObjectRelease(iter)
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceInterestCallback = { refcon, _, _, _ in
            guard let refcon else {
                return
            }
            let observer = Unmanaged<DisplayConnectionObserver>.fromOpaque(refcon).takeUnretainedValue()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                observer.onChange()
            }
        }

        while true {
            let service = IOIteratorNext(iter)
            guard service != IO_OBJECT_NULL else {
                break
            }
            defer {
                IOObjectRelease(service)
            }

            var notifier: io_object_t = IO_OBJECT_NULL
            let kr = IOServiceAddInterestNotification(
                port,
                service,
                kIOGeneralInterest,
                callback,
                refcon,
                &notifier
            )
            if kr == KERN_SUCCESS, notifier != IO_OBJECT_NULL {
                notifiers.append(notifier)
            }
        }
    }

    deinit {
        for notifier in notifiers where notifier != IO_OBJECT_NULL {
            IOObjectRelease(notifier)
        }
        if let notificationPort {
            IONotificationPortDestroy(notificationPort)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let text = LocalizedText()
    private let autoSettings = AutoSwitchSettings.shared
    private var toggleItem = NSMenuItem()
    private var lastStatus = DisplayStatus(
        layout: .unknown,
        online: nil,
        mirror: nil,
        activeExternalCount: nil,
        physicalExternalCount: nil,
        hardwareExternalKeys: nil,
        lastHardwareUnplugEvent: nil,
        lastHardwarePlugEvent: nil,
        rawText: ""
    )
    private var isBusy = false
    private var refreshTimer: Timer?
    private var displayConnectionObserver: DisplayConnectionObserver?
    private var autoPausedAtPhysicalExternalCount: Int?
    private var lastSeenHardwareUnplugEvent: UInt64?
    private var lastSeenHardwarePlugEvent: UInt64?
    private var pendingRestoreUnplugEvent: UInt64?
    private var pendingAutoOffPlugEvent: UInt64?
    private var settingsWindowController: SettingsWindowController?
    private let helper = ClamlessHelper()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildMenu()
        registerDisplayCallback()
        displayConnectionObserver = DisplayConnectionObserver { [weak self] in
            self?.refreshAndApplyAutoSwitch()
        }
        refreshStatus { [weak self] status in
            self?.markHardwareEventsSeen(status)
            self?.applyAutoSwitch(status: status)
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshAndApplyAutoSwitch()
        }
    }

    private func buildMenu() {
        statusItem.button?.title = "Clamless"
        statusItem.button?.toolTip = "Clamless"
        statusItem.button?.imagePosition = .imageLeading

        toggleItem = NSMenuItem(title: "", action: #selector(toggleBuiltIn), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(.separator())

        let settings = NSMenuItem(title: text.settings, action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: text.quit, action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        updateMenu()
    }

    @objc private func toggleBuiltIn() {
        switch lastStatus.layout {
        case .connected:
            autoPausedAtPhysicalExternalCount = nil
            autoSettings.autoManagedOff = false
            runAction(name: text.actionName(layout: .connected), arguments: ["off", "--commit", "session"], automatic: false)
        case .disconnected:
            if lastStatus.needsOffRepair {
                autoPausedAtPhysicalExternalCount = nil
                runAction(name: text.actionName(layout: .connected), arguments: ["off", "--commit", "session"], automatic: false)
            } else {
                autoPausedAtPhysicalExternalCount = lastStatus.physicalExternalCount
                autoSettings.autoManagedOff = false
                runAction(name: text.actionName(layout: .disconnected), arguments: ["on", "--commit", "session"], automatic: false)
            }
        case .unknown:
            refreshStatus()
            showMessage(title: text.unknownStatusTitle, text: text.unknownStatusMessage)
        }
    }

    @objc private func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController { [weak self] in
                self?.refreshAndApplyAutoSwitch()
            }
        }
        settingsWindowController?.showWindow(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func runAction(name: String, arguments: [String], automatic: Bool) {
        guard let helper else {
            showMessage(title: text.helperMissingTitle, text: text.helperMissingMessage)
            return
        }
        guard !isBusy else { return }

        isBusy = true
        updateMenu()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = helper.run(arguments)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false
                if result.exitCode != 0 {
                    if !automatic {
                        self.showMessage(title: self.text.failureTitle(for: name), text: result.combinedText)
                    }
                } else if automatic {
                    if arguments.first == "off" {
                        self.autoSettings.autoManagedOff = true
                    } else if arguments.first == "on" {
                        self.autoSettings.autoManagedOff = false
                    }
                }
                self.refreshStatus { status in
                    if arguments.first == "on" || arguments.first == "off" {
                        self.markHardwareEventsSeen(status)
                    }
                }
            }
        }
    }

    private func refreshAndApplyAutoSwitch() {
        refreshStatus { [weak self] status in
            self?.applyAutoSwitch(status: status)
        }
    }

    private func refreshStatus(completion: ((DisplayStatus) -> Void)? = nil) {
        guard let helper else {
            lastStatus = DisplayStatus(
                layout: .unknown,
                online: nil,
                mirror: nil,
                activeExternalCount: nil,
                physicalExternalCount: nil,
                hardwareExternalKeys: nil,
                lastHardwareUnplugEvent: nil,
                lastHardwarePlugEvent: nil,
                rawText: ""
            )
            updateMenu()
            completion?(lastStatus)
            return
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = helper.run(["status"])
            let status = Self.parseStatus(result.output + result.error)
            DispatchQueue.main.async {
                guard let self else { return }
                if result.exitCode == 0 {
                    self.lastStatus = status
                } else {
                    self.lastStatus = DisplayStatus(
                        layout: .unknown,
                        online: nil,
                        mirror: nil,
                        activeExternalCount: nil,
                        physicalExternalCount: nil,
                        hardwareExternalKeys: nil,
                        lastHardwareUnplugEvent: nil,
                        lastHardwarePlugEvent: nil,
                        rawText: result.combinedText
                    )
                }
                self.updateMenu()
                completion?(self.lastStatus)
            }
        }
    }

    private func applyAutoSwitch(status: DisplayStatus) {
        guard autoSettings.autoEnabled, helper != nil, !isBusy else {
            return
        }

        recordNewHardwareEvents(status)
        normalizeAutoManagedState(status)

        if handleLostExternalLayout(status) {
            return
        }

        if handlePendingRestore(status) {
            return
        }

        if handlePendingAutoOff(status) {
            return
        }
    }

    private func markHardwareEventsSeen(_ status: DisplayStatus) {
        if let unplug = status.lastHardwareUnplugEvent {
            lastSeenHardwareUnplugEvent = max(lastSeenHardwareUnplugEvent ?? 0, unplug)
        }
        if let plug = status.lastHardwarePlugEvent {
            lastSeenHardwarePlugEvent = max(lastSeenHardwarePlugEvent ?? 0, plug)
        }
    }

    private func recordNewHardwareEvents(_ status: DisplayStatus) {
        if let unplug = status.lastHardwareUnplugEvent,
           let previous = lastSeenHardwareUnplugEvent,
           unplug > previous {
            lastSeenHardwareUnplugEvent = unplug
            pendingRestoreUnplugEvent = unplug
            pendingAutoOffPlugEvent = nil
        }

        if let plug = status.lastHardwarePlugEvent,
           let previous = lastSeenHardwarePlugEvent,
           plug > previous {
            lastSeenHardwarePlugEvent = plug
            if pendingRestoreUnplugEvent == nil {
                pendingAutoOffPlugEvent = plug
            }
        }
    }

    private func normalizeAutoManagedState(_ status: DisplayStatus) {
        guard status.layout == .disconnected, allowedExternalActive(status) else {
            return
        }
        autoSettings.autoManagedOff = true
    }

    private func handleLostExternalLayout(_ status: DisplayStatus) -> Bool {
        guard status.layout == .disconnected,
              status.activeExternalCount == 0 else {
            return false
        }

        pendingRestoreUnplugEvent = status.lastHardwareUnplugEvent ?? pendingRestoreUnplugEvent ?? 0
        pendingAutoOffPlugEvent = nil
        runAction(name: text.actionName(layout: .disconnected), arguments: ["on", "--commit", "session"], automatic: true)
        return true
    }

    private func handlePendingRestore(_ status: DisplayStatus) -> Bool {
        guard pendingRestoreUnplugEvent != nil else {
            return false
        }

        if status.layout == .connected {
            pendingRestoreUnplugEvent = nil
            pendingAutoOffPlugEvent = nil
            autoSettings.autoManagedOff = false
            return false
        }

        guard status.layout == .disconnected else {
            return true
        }

        runAction(name: text.actionName(layout: .disconnected), arguments: ["on", "--commit", "session"], automatic: true)
        return true
    }

    private func handlePendingAutoOff(_ status: DisplayStatus) -> Bool {
        guard pendingRestoreUnplugEvent == nil else {
            return true
        }

        guard pendingAutoOffPlugEvent != nil else {
            return false
        }

        guard allowedExternalActive(status) else {
            return false
        }

        if let pausedCount = autoPausedAtPhysicalExternalCount,
           pausedCount == status.physicalExternalCount {
            return false
        }
        autoPausedAtPhysicalExternalCount = nil

        if status.layout == .connected || status.needsOffRepair {
            autoSettings.autoManagedOff = true
            pendingAutoOffPlugEvent = nil
            runAction(name: text.actionName(layout: .connected), arguments: ["off", "--commit", "session"], automatic: true)
            return true
        }

        if status.layout == .disconnected {
            autoSettings.autoManagedOff = true
            pendingAutoOffPlugEvent = nil
        }
        return false
    }

    private func allowedExternalActive(_ status: DisplayStatus) -> Bool {
        guard (status.physicalExternalCount ?? 0) > 0,
              let hardwareExternalKeys = status.hardwareExternalKeys else {
            return false
        }
        return !hardwareExternalKeys.intersection(autoSettings.allowedDisplayKeys).isEmpty
    }

    private func registerDisplayCallback() {
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback({ display, flags, userInfo in
            guard let userInfo, !flags.contains(.beginConfigurationFlag) else {
                return
            }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                delegate.refreshAndApplyAutoSwitch()
            }
        }, pointer)
    }

    private static func parseStatus(_ text: String) -> DisplayStatus {
        var layout: LayoutState = .unknown
        var online: Bool?
        var mirror: Bool?
        var externalCount: Int?
        var physicalExternalCount: Int?
        var hardwareExternalKeys: Set<String>?
        var lastHardwareUnplugEvent: UInt64?
        var lastHardwarePlugEvent: UInt64?

        for line in text.split(separator: "\n") {
            if line.hasPrefix("summary:") {
                if line.contains("layout=connected") {
                    layout = .connected
                } else if line.contains("layout=disconnected") {
                    layout = .disconnected
                }

                if line.contains("online=yes") {
                    online = true
                } else if line.contains("online=no") {
                    online = false
                }

                if line.contains("mirror=yes") {
                    mirror = true
                } else if line.contains("mirror=no") {
                    mirror = false
                }

                if let range = line.range(of: "active_external_count=") {
                    let tail = line[range.upperBound...]
                    let digits = tail.prefix { $0.isNumber }
                    externalCount = Int(digits)
                }

                if let range = line.range(of: "physical_external_count=") {
                    let tail = line[range.upperBound...]
                    let digits = tail.prefix { $0.isNumber }
                    physicalExternalCount = Int(digits)
                }
            } else if line.hasPrefix("hardware:") {
                if let range = line.range(of: "external_keys=") {
                    let tail = line[range.upperBound...]
                    let token = tail.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
                    if token == "none" {
                        hardwareExternalKeys = []
                    } else if token != "unknown" && !token.isEmpty {
                        hardwareExternalKeys = Set(token.split(separator: ",").map(String.init))
                    }
                }

                if let range = line.range(of: "last_unplug_event=") {
                    let tail = line[range.upperBound...]
                    let digits = tail.prefix { $0.isNumber }
                    lastHardwareUnplugEvent = UInt64(digits)
                }

                if let range = line.range(of: "last_plug_event=") {
                    let tail = line[range.upperBound...]
                    let digits = tail.prefix { $0.isNumber }
                    lastHardwarePlugEvent = UInt64(digits)
                }
            }
        }

        return DisplayStatus(
            layout: layout,
            online: online,
            mirror: mirror,
            activeExternalCount: externalCount,
            physicalExternalCount: physicalExternalCount,
            hardwareExternalKeys: hardwareExternalKeys,
            lastHardwareUnplugEvent: lastHardwareUnplugEvent,
            lastHardwarePlugEvent: lastHardwarePlugEvent,
            rawText: text
        )
    }

    private func updateMenu() {
        let externalCount = lastStatus.physicalExternalCount ?? lastStatus.activeExternalCount ?? 0
        let helperAvailable = helper != nil

        statusItem.button?.title = text.statusTitle(
            status: lastStatus,
            isBusy: isBusy,
            helperAvailable: helperAvailable
        )
        statusItem.button?.image = statusIcon(for: lastStatus)
        statusItem.button?.imagePosition = .imageLeading

        toggleItem.title = text.toggleTitle(
            status: lastStatus,
            externalCount: externalCount,
            helperAvailable: helperAvailable,
            isBusy: isBusy
        )

        let canTurnOff = (lastStatus.layout == .connected && externalCount > 0) || lastStatus.needsOffRepair
        let canTurnOn = lastStatus.layout == .disconnected
        let canRefresh = lastStatus.layout == .unknown
        toggleItem.isEnabled = helperAvailable && !isBusy && (canTurnOff || canTurnOn || canRefresh)
    }

    private func statusIcon(for status: DisplayStatus) -> NSImage? {
        let symbolName: String
        switch status.layout {
        case .connected:
            symbolName = "macbook"
        case .disconnected:
            symbolName = "display"
        case .unknown:
            symbolName = "questionmark.square"
        }

        guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Clamless") else {
            return nil
        }
        image.isTemplate = true
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    private func showMessage(title: String, text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text.isEmpty ? self.text.noMoreInfo : text
        alert.alertStyle = .warning
        alert.addButton(withTitle: self.text.ok)
        alert.runModal()
    }
}

if !LoginItemManager.runCommandIfRequested(CommandLine.arguments) {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
