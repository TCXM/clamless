import Carbon
import Cocoa
import Darwin
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
    let builtinDisplayID: CGDirectDisplayID?
    let online: Bool?
    let mirror: Bool?
    let activeExternalCount: Int?
    let physicalExternalCount: Int?
    let liveExternalCount: Int?
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

struct DisplayHotKey: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let key: String

    static let defaultToggle = DisplayHotKey(
        keyCode: UInt32(kVK_ANSI_D),
        modifiers: UInt32(cmdKey | optionKey | controlKey),
        key: "D"
    )

    var displayString: String {
        var prefix = ""
        if modifiers & UInt32(controlKey) != 0 { prefix += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { prefix += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { prefix += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { prefix += "⌘" }
        return prefix + (key.isEmpty ? "Key \(keyCode)" : key)
    }

    static func from(event: NSEvent) -> DisplayHotKey? {
        let modifiers = carbonModifiers(from: event.modifierFlags)
        guard hasUsableModifier(modifiers) else {
            return nil
        }

        let key = displayKey(for: event)
        guard !key.isEmpty else {
            return nil
        }

        return DisplayHotKey(
            keyCode: UInt32(event.keyCode),
            modifiers: modifiers,
            key: key
        )
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        return modifiers
    }

    private static func hasUsableModifier(_ modifiers: UInt32) -> Bool {
        modifiers & UInt32(cmdKey | optionKey | controlKey) != 0
    }

    private static func displayKey(for event: NSEvent) -> String {
        if let special = specialKeyNames[UInt32(event.keyCode)] {
            return special
        }

        let characters = event.charactersIgnoringModifiers?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased() ?? ""
        return characters.isEmpty ? "" : characters
    }

    private static let specialKeyNames: [UInt32: String] = [
        UInt32(kVK_Return): "↩",
        UInt32(kVK_Tab): "⇥",
        UInt32(kVK_Space): "Space",
        UInt32(kVK_Delete): "⌫",
        UInt32(kVK_ForwardDelete): "⌦",
        UInt32(kVK_Escape): "Esc",
        UInt32(kVK_F1): "F1",
        UInt32(kVK_F2): "F2",
        UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4",
        UInt32(kVK_F5): "F5",
        UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7",
        UInt32(kVK_F8): "F8",
        UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10",
        UInt32(kVK_F11): "F11",
        UInt32(kVK_F12): "F12"
    ]
}

final class DebugLog {
    static let shared = DebugLog()

    private let queue = DispatchQueue(label: "local.clamless.debug-log")
    private let fileURL: URL?
    private let maxBytes: UInt64 = 512 * 1024

    private init() {
        guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            fileURL = nil
            return
        }

        let directory = library.appendingPathComponent("Logs/Clamless", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("debug.log")
    }

    var path: String {
        fileURL?.path ?? ""
    }

    func write(_ message: String) {
        queue.async { [fileURL, maxBytes] in
            guard let fileURL else { return }
            Self.rotateIfNeeded(fileURL: fileURL, maxBytes: maxBytes)

            let timestamp = ISO8601DateFormatter().string(from: Date())
            let sanitized = message
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
            guard let data = "[\(timestamp)] \(sanitized)\n".data(using: .utf8) else {
                return
            }

            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }

            guard let handle = try? FileHandle(forWritingTo: fileURL) else {
                return
            }
            defer {
                try? handle.close()
            }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    private static func rotateIfNeeded(fileURL: URL, maxBytes: UInt64) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? UInt64,
              size > maxBytes else {
            return
        }

        let rotated = fileURL.deletingLastPathComponent()
            .appendingPathComponent(fileURL.lastPathComponent + ".1")
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: fileURL, to: rotated)
    }
}

final class GlobalHotKeyManager {
    private static let signature: OSType = 0x434C4D53 // CLMS
    private static let hotKeyID: UInt32 = 1

    private var handlerRef: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        installHandler()
    }

    deinit {
        unregister()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }

    func register(_ hotKey: DisplayHotKey?) {
        unregister()

        guard let hotKey else {
            DebugLog.shared.write("hotkey disabled")
            return
        }

        let id = EventHotKeyID(signature: Self.signature, id: Self.hotKeyID)
        var nextHotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            hotKey.keyCode,
            hotKey.modifiers,
            id,
            GetApplicationEventTarget(),
            0,
            &nextHotKeyRef
        )

        guard status == noErr, let nextHotKeyRef else {
            DebugLog.shared.write("hotkey register failed shortcut=\(hotKey.displayString) status=\(status)")
            return
        }

        hotKeyRef = nextHotKeyRef
        DebugLog.shared.write("hotkey registered shortcut=\(hotKey.displayString)")
    }

    private func unregister() {
        guard let hotKeyRef else { return }
        UnregisterEventHotKey(hotKeyRef)
        self.hotKeyRef = nil
    }

    private func installHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else {
                    return OSStatus(eventNotHandledErr)
                }

                let manager = Unmanaged<GlobalHotKeyManager>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                DispatchQueue.main.async {
                    manager.action()
                }
                return noErr
            },
            1,
            &eventType,
            refcon,
            &handlerRef
        )

        if status != noErr {
            DebugLog.shared.write("hotkey handler install failed status=\(status)")
        }
    }
}

extension LayoutState {
    var debugName: String {
        switch self {
        case .connected: return "connected"
        case .disconnected: return "disconnected"
        case .unknown: return "unknown"
        }
    }
}

extension DisplayStatus {
    var debugSummary: String {
        let builtin = builtinDisplayID.map { String($0) } ?? "nil"
        let active = activeExternalCount.map(String.init) ?? "nil"
        let physical = physicalExternalCount.map(String.init) ?? "nil"
        let live = liveExternalCount.map(String.init) ?? "nil"
        let unplug = lastHardwareUnplugEvent.map(String.init) ?? "nil"
        let plug = lastHardwarePlugEvent.map(String.init) ?? "nil"
        let keys = hardwareExternalKeys.map { $0.sorted().joined(separator: ",") } ?? "nil"
        return "layout=\(layout.debugName) builtin_id=\(builtin) online=\(online.map(String.init) ?? "nil") mirror=\(mirror.map(String.init) ?? "nil") active=\(active) physical=\(physical) live=\(live) unplug=\(unplug) plug=\(plug) keys=\(keys)"
    }
}

struct UpdateInfo {
    let currentVersion: String
    let latestVersion: String
    let releaseURL: URL
}

enum UpdateCheckResult {
    case available(UpdateInfo)
    case upToDate(currentVersion: String)
}

enum UpdateCheckError: LocalizedError {
    case httpStatus(Int)
    case invalidResponse
    case missingCurrentVersion

    var errorDescription: String? {
        switch self {
        case .httpStatus(let statusCode):
            return "GitHub returned HTTP \(statusCode)."
        case .invalidResponse:
            return "GitHub returned an invalid release response."
        case .missingCurrentVersion:
            return "The current app version could not be read."
        }
    }
}

enum UpdateChecker {
    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlURL: URL

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/TCXM/clamless/releases/latest")!

    static func check(completion: @escaping (Result<UpdateCheckResult, Error>) -> Void) {
        guard let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !currentVersion.isEmpty else {
            completion(.failure(UpdateCheckError.missingCurrentVersion))
            return
        }

        var request = URLRequest(url: latestReleaseURL)
        request.timeoutInterval = 10
        request.setValue("Clamless/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse,
                  let data else {
                completion(.failure(UpdateCheckError.invalidResponse))
                return
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                completion(.failure(UpdateCheckError.httpStatus(httpResponse.statusCode)))
                return
            }

            do {
                let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
                let latestVersion = normalizedVersion(release.tagName)
                if isVersion(latestVersion, newerThan: currentVersion) {
                    completion(.success(.available(UpdateInfo(
                        currentVersion: currentVersion,
                        latestVersion: latestVersion,
                        releaseURL: release.htmlURL
                    ))))
                } else {
                    completion(.success(.upToDate(currentVersion: currentVersion)))
                }
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    private static func normalizedVersion(_ version: String) -> String {
        version
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingPrefix("v")
            .trimmingPrefix("V")
            .split(whereSeparator: { $0 == "-" || $0 == "+" })
            .first
            .map(String.init) ?? version
    }

    private static func isVersion(_ latestVersion: String, newerThan currentVersion: String) -> Bool {
        normalizedVersion(latestVersion)
            .compare(normalizedVersion(currentVersion), options: [.numeric, .caseInsensitive]) == .orderedDescending
    }
}

extension String {
    fileprivate func trimmingPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
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

    var checkForUpdates: String {
        value("check_for_updates")
    }

    var checkingForUpdates: String {
        value("checking_for_updates")
    }

    var updateAvailableTitle: String {
        value("update_available_title")
    }

    var downloadUpdate: String {
        value("download_update")
    }

    var later: String {
        value("later")
    }

    var upToDateTitle: String {
        value("up_to_date_title")
    }

    var updateCheckFailedTitle: String {
        value("update_check_failed_title")
    }

    var settingsTitle: String {
        value("settings_title")
    }

    var autoSwitchEnabled: String {
        value("auto_switch_enabled")
    }

    var automaticSwitchingSection: String {
        value("automatic_switching_section")
    }

    var generalSection: String {
        value("general_section")
    }

    var keyboardShortcutSection: String {
        value("keyboard_shortcut_section")
    }

    var toggleShortcut: String {
        value("toggle_shortcut")
    }

    var recordShortcut: String {
        value("record_shortcut")
    }

    var recordShortcutPrompt: String {
        value("record_shortcut_prompt")
    }

    var clearShortcut: String {
        value("clear_shortcut")
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

    func updateAvailableMessage(latestVersion: String, currentVersion: String) -> String {
        String(format: value("update_available_message_format"), latestVersion, currentVersion)
    }

    func upToDateMessage(currentVersion: String) -> String {
        String(format: value("up_to_date_message_format"), currentVersion)
    }

    func updateCheckFailedMessage(_ reason: String) -> String {
        String(format: value("update_check_failed_message_format"), reason)
    }
}

final class AutoSwitchSettings {
    static let shared = AutoSwitchSettings()

    private let defaults = UserDefaults.standard
    private let autoEnabledKey = "autoSwitchEnabled"
    private let allowedDisplaysKey = "autoSwitchAllowedDisplayKeys"
    private let autoManagedOffKey = "autoSwitchManagedOff"
    private let lastBuiltinDisplayIDKey = "lastBuiltinDisplayID"
    private let toggleHotKeyKey = "toggleHotKey"
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

    var lastBuiltinDisplayID: CGDirectDisplayID? {
        get {
            let value = defaults.integer(forKey: lastBuiltinDisplayIDKey)
            return value > 0 ? CGDirectDisplayID(value) : nil
        }
        set {
            if let newValue, newValue > 0 {
                defaults.set(Int(newValue), forKey: lastBuiltinDisplayIDKey)
            } else {
                defaults.removeObject(forKey: lastBuiltinDisplayIDKey)
            }
        }
    }

    var toggleHotKey: DisplayHotKey? {
        get {
            guard let stored = defaults.object(forKey: toggleHotKeyKey) else {
                return .defaultToggle
            }

            guard let data = stored as? Data, !data.isEmpty else {
                return nil
            }

            return (try? JSONDecoder().decode(DisplayHotKey.self, from: data)) ?? .defaultToggle
        }
        set {
            guard let newValue else {
                defaults.set(Data(), forKey: toggleHotKeyKey)
                return
            }

            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: toggleHotKeyKey)
            }
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
    private weak var checkUpdatesButton: NSButton?
    private weak var shortcutButton: NSButton?
    private var shortcutRecordingMonitor: Any?
    private var isRecordingShortcut = false
    private var isCheckingForUpdates = false

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 420),
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

    deinit {
        stopRecordingShortcut()
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
        stack.spacing = 10
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

        stack.addArrangedSubview(sectionLabel(text.automaticSwitchingSection))

        let enable = NSButton(checkboxWithTitle: text.autoSwitchEnabled, target: self, action: #selector(toggleAutoSwitch(_:)))
        enable.state = settings.autoEnabled ? .on : .off
        stack.addArrangedSubview(enable)

        let displays = DisplayInventory.activeExternalDisplays()
        if displays.isEmpty {
            let label = NSTextField(labelWithString: text.noExternalDisplays)
            label.textColor = .secondaryLabelColor
            stack.addArrangedSubview(indented(label))
        } else {
            let allowed = settings.allowedDisplayKeys
            for display in displays {
                let checkbox = NSButton(checkboxWithTitle: display.name, target: self, action: #selector(toggleDisplay(_:)))
                checkbox.identifier = NSUserInterfaceItemIdentifier(display.key)
                checkbox.toolTip = display.key
                checkbox.state = allowed.contains(display.key) ? .on : .off
                stack.addArrangedSubview(indented(checkbox))
            }
        }

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(sectionLabel(text.generalSection))

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
            stack.addArrangedSubview(indented(approvalStack))
        }

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(sectionLabel(text.keyboardShortcutSection))
        stack.addArrangedSubview(shortcutRow())

        stack.addArrangedSubview(separator())
        let checkUpdates = NSButton(
            title: isCheckingForUpdates ? text.checkingForUpdates : text.checkForUpdates,
            target: self,
            action: #selector(checkForUpdates)
        )
        checkUpdates.bezelStyle = .rounded
        checkUpdates.isEnabled = !isCheckingForUpdates
        checkUpdatesButton = checkUpdates
        stack.addArrangedSubview(checkUpdates)

        stack.addArrangedSubview(separator())
        let closeButton = NSButton(title: text.close, target: self, action: #selector(closeWindow))
        closeButton.bezelStyle = .rounded
        stack.addArrangedSubview(closeButton)
    }

    private func sectionLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func separator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.widthAnchor.constraint(equalToConstant: 408).isActive = true
        return separator
    }

    private func shortcutRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8

        let label = NSTextField(labelWithString: text.toggleShortcut)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 150).isActive = true

        let record = NSButton(
            title: shortcutButtonTitle(),
            target: self,
            action: #selector(recordToggleShortcut)
        )
        record.bezelStyle = .rounded
        record.translatesAutoresizingMaskIntoConstraints = false
        record.widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        shortcutButton = record

        let clear = NSButton(
            title: text.clearShortcut,
            target: self,
            action: #selector(clearToggleShortcut)
        )
        clear.bezelStyle = .rounded
        clear.isEnabled = settings.toggleHotKey != nil

        row.addArrangedSubview(label)
        row.addArrangedSubview(record)
        row.addArrangedSubview(clear)
        return indented(row)
    }

    private func shortcutButtonTitle() -> String {
        if isRecordingShortcut {
            return text.recordShortcutPrompt
        }
        return settings.toggleHotKey?.displayString ?? text.recordShortcut
    }

    private func indented(_ view: NSView) -> NSView {
        let wrapper = NSStackView()
        wrapper.orientation = .horizontal
        wrapper.alignment = .centerY
        wrapper.spacing = 0

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.widthAnchor.constraint(equalToConstant: 24).isActive = true

        wrapper.addArrangedSubview(spacer)
        wrapper.addArrangedSubview(view)
        return wrapper
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

    @objc private func recordToggleShortcut() {
        guard !isRecordingShortcut else {
            stopRecordingShortcut()
            shortcutButton?.title = shortcutButtonTitle()
            return
        }

        isRecordingShortcut = true
        shortcutButton?.title = shortcutButtonTitle()
        window?.makeKeyAndOrderFront(nil)

        shortcutRecordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.captureShortcut(event)
            return nil
        }
    }

    @objc private func clearToggleShortcut() {
        stopRecordingShortcut()
        settings.toggleHotKey = nil
        onChange()
        rebuild()
    }

    @objc private func checkForUpdates() {
        guard !isCheckingForUpdates else { return }

        setCheckingForUpdates(true)

        UpdateChecker.check { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.setCheckingForUpdates(false)

                switch result {
                case .success(.available(let info)):
                    self.showUpdateAvailable(info)
                case .success(.upToDate(let currentVersion)):
                    self.showMessage(
                        title: self.text.upToDateTitle,
                        text: self.text.upToDateMessage(currentVersion: currentVersion),
                        style: .informational
                    )
                case .failure(let error):
                    self.showMessage(
                        title: self.text.updateCheckFailedTitle,
                        text: self.text.updateCheckFailedMessage(error.localizedDescription),
                        style: .warning
                    )
                }
            }
        }
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
        stopRecordingShortcut()
        window?.close()
    }

    private func captureShortcut(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            stopRecordingShortcut()
            rebuild()
            return
        }

        if event.keyCode == UInt16(kVK_Delete) ||
            event.keyCode == UInt16(kVK_ForwardDelete) {
            settings.toggleHotKey = nil
            stopRecordingShortcut()
            onChange()
            rebuild()
            return
        }

        guard let hotKey = DisplayHotKey.from(event: event) else {
            NSSound.beep()
            return
        }

        settings.toggleHotKey = hotKey
        stopRecordingShortcut()
        onChange()
        rebuild()
    }

    private func stopRecordingShortcut() {
        if let shortcutRecordingMonitor {
            NSEvent.removeMonitor(shortcutRecordingMonitor)
        }
        shortcutRecordingMonitor = nil
        isRecordingShortcut = false
    }

    private func setCheckingForUpdates(_ checking: Bool) {
        isCheckingForUpdates = checking
        checkUpdatesButton?.title = checking ? text.checkingForUpdates : text.checkForUpdates
        checkUpdatesButton?.isEnabled = !checking
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

    private func showMessage(title: String, text: String, style: NSAlert.Style) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text.isEmpty ? self.text.noMoreInfo : text
        alert.alertStyle = style
        alert.addButton(withTitle: self.text.ok)
        alert.runModal()
    }

    private func showUpdateAvailable(_ info: UpdateInfo) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = text.updateAvailableTitle
        alert.informativeText = text.updateAvailableMessage(
            latestVersion: info.latestVersion,
            currentVersion: info.currentVersion
        )
        alert.alertStyle = .informational
        alert.addButton(withTitle: text.downloadUpdate)
        alert.addButton(withTitle: text.later)

        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(info.releaseURL)
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

    func run(_ arguments: [String], timeout: TimeInterval? = nil) -> HelperResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        var didTimeOut = false
        let terminationSemaphore: DispatchSemaphore?
        if timeout != nil {
            let semaphore = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in
                semaphore.signal()
            }
            terminationSemaphore = semaphore
        } else {
            terminationSemaphore = nil
        }

        do {
            try process.run()
            if let timeout, let terminationSemaphore {
                if terminationSemaphore.wait(timeout: .now() + timeout) == .timedOut {
                    didTimeOut = true
                    process.terminate()
                    process.waitUntilExit()
                }
            } else {
                process.waitUntilExit()
            }
        } catch {
            return HelperResult(exitCode: 127, output: "", error: error.localizedDescription)
        }

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        return HelperResult(
            exitCode: didTimeOut ? 124 : process.terminationStatus,
            output: String(data: outData, encoding: .utf8) ?? "",
            error: didTimeOut ? "clamless-display timed out" : (String(data: errData, encoding: .utf8) ?? "")
        )
    }
}

final class DisplayConnectionObserver {
    private var notificationPort: IONotificationPortRef?
    private var notifiers = [io_object_t]()
    private var matchingIterators = [io_iterator_t]()
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

        addServiceNotifications(for: "AppleATCDPAltModePort", port: port)
        addServiceNotifications(for: "AppleDCPDPTXRemotePortUFP", port: port)
        addServiceNotifications(for: "AppleDisplayCrossbar", port: port)
        addServiceNotifications(for: "AppleT8132DisplayCrossbar", port: port)
        addServiceNotifications(for: "AppleT603XDisplayCrossbar", port: port)
        addServiceNotifications(for: "AppleT8112DisplayCrossbar", port: port)
        addServiceNotifications(for: "AppleT8122DisplayCrossbar", port: port)
        addServiceNotifications(for: "AppleT8140DisplayCrossbar", port: port)
        addServiceNotifications(for: "AppleDisplayConnectionManager", port: port)

        if notifiers.isEmpty && matchingIterators.isEmpty {
            IONotificationPortDestroy(port)
            notificationPort = nil
            return nil
        }
    }

    private func addServiceNotifications(for className: String, port: IONotificationPortRef) {
        addFirstMatchNotification(for: className, port: port)
        addTerminatedNotification(for: className, port: port)
    }

    private func addFirstMatchNotification(for className: String, port: IONotificationPortRef) {
        guard let match = IOServiceMatching(className) else {
            return
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else {
                return
            }
            let observer = Unmanaged<DisplayConnectionObserver>.fromOpaque(refcon).takeUnretainedValue()
            observer.drainMatchedServices(iterator, notify: true)
        }

        var iter: io_iterator_t = IO_OBJECT_NULL
        let kr = IOServiceAddMatchingNotification(
            port,
            kIOFirstMatchNotification,
            match,
            callback,
            refcon,
            &iter
        )
        guard kr == KERN_SUCCESS, iter != IO_OBJECT_NULL else {
            return
        }
        matchingIterators.append(iter)
        drainMatchedServices(iter, notify: false)
    }

    private func addTerminatedNotification(for className: String, port: IONotificationPortRef) {
        guard let match = IOServiceMatching(className) else {
            return
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else {
                return
            }
            let observer = Unmanaged<DisplayConnectionObserver>.fromOpaque(refcon).takeUnretainedValue()
            observer.drainIterator(iterator, notify: true)
        }

        var iter: io_iterator_t = IO_OBJECT_NULL
        let kr = IOServiceAddMatchingNotification(
            port,
            kIOTerminatedNotification,
            match,
            callback,
            refcon,
            &iter
        )
        guard kr == KERN_SUCCESS, iter != IO_OBJECT_NULL else {
            return
        }
        matchingIterators.append(iter)
        drainIterator(iter, notify: false)
    }

    private func drainMatchedServices(_ iterator: io_iterator_t, notify: Bool) {
        guard let port = notificationPort else {
            drainIterator(iterator, notify: notify)
            return
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceInterestCallback = { refcon, _, _, _ in
            guard let refcon else {
                return
            }
            let observer = Unmanaged<DisplayConnectionObserver>.fromOpaque(refcon).takeUnretainedValue()
            observer.scheduleChangeRefresh()
        }

        while true {
            let service = IOIteratorNext(iterator)
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

        if notify {
            scheduleChangeRefresh()
        }
    }

    private func drainIterator(_ iterator: io_iterator_t, notify: Bool) {
        while true {
            let service = IOIteratorNext(iterator)
            guard service != IO_OBJECT_NULL else {
                break
            }
            IOObjectRelease(service)
        }

        if notify {
            scheduleChangeRefresh()
        }
    }

    private func scheduleChangeRefresh() {
        DebugLog.shared.write("display observer notification")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.onChange()
        }
    }

    deinit {
        for notifier in notifiers where notifier != IO_OBJECT_NULL {
            IOObjectRelease(notifier)
        }
        for iterator in matchingIterators where iterator != IO_OBJECT_NULL {
            IOObjectRelease(iterator)
        }
        if let notificationPort {
            IONotificationPortDestroy(notificationPort)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum TerminationState {
        case running
        case restoring
        case restored
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let text = LocalizedText()
    private let autoSettings = AutoSwitchSettings.shared
    private var toggleItem = NSMenuItem()
    private var lastStatus = DisplayStatus(
        layout: .unknown,
        builtinDisplayID: nil,
        online: nil,
        mirror: nil,
        activeExternalCount: nil,
        physicalExternalCount: nil,
        liveExternalCount: nil,
        hardwareExternalKeys: nil,
        lastHardwareUnplugEvent: nil,
        lastHardwarePlugEvent: nil,
        rawText: ""
    )
    private var isBusy = false
    // A full status refresh launches the helper and scans display hardware, so
    // keep 1 Hz polling only while display state is settling.
    private let activeRefreshInterval: TimeInterval = 1
    private let idleRefreshInterval: TimeInterval = 30
    private let displaySettleRefreshDuration: TimeInterval = 10
    private let hardwareEventRefreshDuration: TimeInterval = 20
    private var refreshTimer: Timer?
    private var refreshTimerInterval: TimeInterval?
    private var fastRefreshUntil: Date?
    private var scheduledRefreshGeneration = 0
    private var isAutoRefreshInFlight = false
    private var autoRefreshQueued = false
    private var lastKnownBuiltinDisplayID: CGDirectDisplayID?
    private var displayConnectionObserver: DisplayConnectionObserver?
    private var autoPausedAtPhysicalExternalCount: Int?
    private var lastSeenHardwareUnplugEvent: UInt64?
    private var lastSeenHardwarePlugEvent: UInt64?
    private var pendingRestoreUnplugEvent: UInt64?
    private var pendingAutoOffPlugEvent: UInt64?
    private var hotKeyManager: GlobalHotKeyManager?
    private var settingsWindowController: SettingsWindowController?
    private var terminationState = TerminationState.running
    private var isTerminating = false
    private var terminationSignalSources = [DispatchSourceSignal]()
    private let helper = ClamlessHelper()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        lastKnownBuiltinDisplayID = autoSettings.lastBuiltinDisplayID
        buildMenu()
        registerTerminationSignalHandlers()
        registerDisplayCallback()
        hotKeyManager = GlobalHotKeyManager { [weak self] in
            self?.handleToggleHotKey()
        }
        hotKeyManager?.register(autoSettings.toggleHotKey)
        displayConnectionObserver = DisplayConnectionObserver { [weak self] in
            self?.scheduleDisplayChangeRefresh(after: 0)
        }
        DebugLog.shared.write(
            "launch version=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown") " +
            "helper=\(helper?.executableURL.path ?? "missing") log=\(DebugLog.shared.path) " +
            "autoEnabled=\(autoSettings.autoEnabled) autoManagedOff=\(autoSettings.autoManagedOff) " +
            "builtinHint=\(lastKnownBuiltinDisplayID.map { String($0) } ?? "nil") " +
            "hotkey=\(autoSettings.toggleHotKey?.displayString ?? "disabled") " +
            "allowed=\(autoSettings.allowedDisplayKeys.sorted().joined(separator: ","))"
        )
        beginFastRefreshWindow()
        refreshStatus { [weak self] status in
            DebugLog.shared.write("initial status \(status.debugSummary)")
            self?.markHardwareEventsSeen(status)
            self?.applyAutoSwitch(status: status)
            self?.configureRefreshTimer()
        }
        configureRefreshTimer()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switch terminationState {
        case .running:
            terminationState = .restoring
            restoreBuiltInBeforeTermination(deadline: Date().addingTimeInterval(8)) { [weak self] in
                guard let self else { return }
                self.terminationState = .restored
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        case .restoring:
            return .terminateCancel
        case .restored:
            return .terminateNow
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        DebugLog.shared.write("application will terminate")
        cancelScheduledRefresh()
        invalidateRefreshTimer()
        for source in terminationSignalSources {
            source.cancel()
        }
        terminationSignalSources.removeAll()
    }

    private func buildMenu() {
        statusItem.button?.title = ""
        statusItem.button?.toolTip = "Clamless"
        statusItem.button?.imagePosition = .imageOnly

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
        performManualToggle(restoreWhenUnknown: false)
    }

    private func handleToggleHotKey() {
        DebugLog.shared.write("hotkey pressed")
        performManualToggle(restoreWhenUnknown: true)
    }

    private func performManualToggle(restoreWhenUnknown: Bool) {
        guard !isBusy, !isTerminating else {
            DebugLog.shared.write("manual toggle ignored busy=\(isBusy) terminating=\(isTerminating)")
            return
        }

        switch lastStatus.layout {
        case .connected:
            let externalCount = lastStatus.liveExternalCount ??
                lastStatus.physicalExternalCount ??
                lastStatus.activeExternalCount ??
                0
            guard externalCount > 0 || lastStatus.needsOffRepair else {
                DebugLog.shared.write("manual toggle ignored: no external display status=\(lastStatus.debugSummary)")
                return
            }
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
            if restoreWhenUnknown {
                autoPausedAtPhysicalExternalCount = nil
                autoSettings.autoManagedOff = false
                DebugLog.shared.write("manual toggle restoring from unknown status=\(lastStatus.debugSummary)")
                runAction(name: text.actionName(layout: .disconnected), arguments: ["on", "--commit", "session"], automatic: false)
            } else {
                refreshStatus()
                showMessage(title: text.unknownStatusTitle, text: text.unknownStatusMessage)
            }
        }
    }

    @objc private func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController { [weak self] in
                self?.handleSettingsChanged()
            }
        }
        settingsWindowController?.showWindow(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func registerTerminationSignalHandlers() {
        for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                self?.handleTerminationSignal()
            }
            source.resume()
            terminationSignalSources.append(source)
        }
    }

    private func handleTerminationSignal() {
        guard terminationState == .running else { return }
        DebugLog.shared.write("termination signal received")
        terminationState = .restoring
        restoreBuiltInBeforeTermination(deadline: Date().addingTimeInterval(8)) {
            exit(0)
        }
    }

    private func restoreBuiltInBeforeTermination(deadline: Date, completion: @escaping () -> Void) {
        DebugLog.shared.write("restore before termination deadline=\(deadline)")
        isTerminating = true
        cancelScheduledRefresh()
        invalidateRefreshTimer()
        displayConnectionObserver = nil
        pendingRestoreUnplugEvent = nil
        pendingAutoOffPlugEvent = nil

        if isBusy, Date() < deadline {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self else {
                    completion()
                    return
                }
                self.restoreBuiltInBeforeTermination(deadline: deadline, completion: completion)
            }
            return
        }

        guard let helper else {
            completion()
            return
        }

        isBusy = true
        updateMenu()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let statusResult = helper.run(["status"], timeout: 2)
            let status = Self.parseStatus(statusResult.output + statusResult.error)
            let shouldRestore = statusResult.exitCode != 0 ||
                status.layout != .connected ||
                status.needsOffRepair ||
                self?.lastStatus.layout == .disconnected ||
                self?.autoSettings.autoManagedOff == true

            DebugLog.shared.write("termination status exit=\(statusResult.exitCode) shouldRestore=\(shouldRestore) status=\(status.debugSummary)")
            if shouldRestore {
                let restoreArguments = self?.argumentsWithBuiltinDisplayHint(["on", "--commit", "session"]) ?? ["on", "--commit", "session"]
                let restoreResult = helper.run(restoreArguments, timeout: 5)
                DebugLog.shared.write("termination restore args=\(restoreArguments.joined(separator: " ")) exit=\(restoreResult.exitCode) text=\(Self.abbreviated(restoreResult.combinedText))")
            }

            DispatchQueue.main.async {
                guard let self else {
                    completion()
                    return
                }
                self.isBusy = false
                self.autoSettings.autoManagedOff = false
                completion()
            }
        }
    }

    private func cacheBuiltinDisplayID(from status: DisplayStatus) {
        guard let id = status.builtinDisplayID, id > 0 else {
            return
        }
        if lastKnownBuiltinDisplayID != id {
            DebugLog.shared.write("builtin display id cached id=\(id)")
        }
        lastKnownBuiltinDisplayID = id
        autoSettings.lastBuiltinDisplayID = id
    }

    private func argumentsWithBuiltinDisplayHint(_ arguments: [String]) -> [String] {
        guard let command = arguments.first,
              command == "on" || command == "layout-on",
              !arguments.contains("--display-id") else {
            return arguments
        }

        guard let id = lastStatus.builtinDisplayID ?? lastKnownBuiltinDisplayID,
              id > 0 else {
            return arguments
        }

        return arguments + ["--display-id", String(id)]
    }

    private func runAction(name: String, arguments: [String], automatic: Bool) {
        guard !isTerminating else { return }
        guard let helper else {
            showMessage(title: text.helperMissingTitle, text: text.helperMissingMessage)
            return
        }
        guard !isBusy else { return }

        let helperArguments = argumentsWithBuiltinDisplayHint(arguments)

        beginFastRefreshWindow()
        configureRefreshTimer()
        isBusy = true
        updateMenu()

        DebugLog.shared.write("action start automatic=\(automatic) name=\(name) args=\(helperArguments.joined(separator: " "))")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = helper.run(helperArguments)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false
                DebugLog.shared.write("action finish automatic=\(automatic) args=\(helperArguments.joined(separator: " ")) exit=\(result.exitCode) text=\(Self.abbreviated(result.combinedText))")
                if result.exitCode != 0 {
                    if !automatic {
                        self.showMessage(title: self.text.failureTitle(for: name), text: result.combinedText)
                    }
                } else if automatic {
                    if helperArguments.first == "off" {
                        self.autoSettings.autoManagedOff = true
                    } else if helperArguments.first == "on" {
                        self.autoSettings.autoManagedOff = false
                    }
                }
                self.refreshStatus { status in
                    if helperArguments.first == "on" || helperArguments.first == "off" {
                        self.markHardwareEventsSeen(status)
                    }
                    self.configureRefreshTimer()
                }
            }
        }
    }

    private func handleSettingsChanged() {
        guard !isTerminating else { return }

        DebugLog.shared.write(
            "settings changed autoEnabled=\(autoSettings.autoEnabled) " +
            "hotkey=\(autoSettings.toggleHotKey?.displayString ?? "disabled") " +
            "allowed=\(autoSettings.allowedDisplayKeys.sorted().joined(separator: ","))"
        )
        hotKeyManager?.register(autoSettings.toggleHotKey)

        if autoSettings.autoEnabled {
            scheduleDisplayChangeRefresh(after: 0)
        } else {
            cancelScheduledRefresh()
            fastRefreshUntil = nil
        }
        configureRefreshTimer()
    }

    private func beginFastRefreshWindow(duration: TimeInterval? = nil) {
        let until = Date().addingTimeInterval(duration ?? displaySettleRefreshDuration)
        if fastRefreshUntil.map({ $0 < until }) ?? true {
            fastRefreshUntil = until
        }
    }

    private var needsFastRefresh: Bool {
        if pendingRestoreUnplugEvent != nil || pendingAutoOffPlugEvent != nil {
            return true
        }
        if let fastRefreshUntil, fastRefreshUntil > Date() {
            return true
        }
        return false
    }

    private func desiredRefreshInterval() -> TimeInterval? {
        guard autoSettings.autoEnabled, !isTerminating else {
            return nil
        }
        if needsFastRefresh {
            return activeRefreshInterval
        }
        return idleRefreshInterval
    }

    private func configureRefreshTimer() {
        guard let interval = desiredRefreshInterval() else {
            invalidateRefreshTimer()
            return
        }

        if refreshTimer != nil, refreshTimerInterval == interval {
            return
        }

        invalidateRefreshTimer()
        DebugLog.shared.write("refresh timer interval=\(interval)")
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.handleRefreshTimer()
        }
        timer.tolerance = interval == activeRefreshInterval ? 0.2 : min(5, interval * 0.2)
        refreshTimer = timer
        refreshTimerInterval = interval
    }

    private func invalidateRefreshTimer() {
        if refreshTimer != nil {
            DebugLog.shared.write("refresh timer invalidated")
        }
        refreshTimer?.invalidate()
        refreshTimer = nil
        refreshTimerInterval = nil
    }

    private func handleRefreshTimer() {
        guard !isTerminating else {
            invalidateRefreshTimer()
            return
        }

        if refreshTimerInterval == activeRefreshInterval, !needsFastRefresh {
            DebugLog.shared.write("active refresh expired; reconfiguring")
            configureRefreshTimer()
            return
        }

        refreshAndApplyAutoSwitch()
    }

    private func scheduleDisplayChangeRefresh(after delay: TimeInterval, extendFastWindow: Bool = true) {
        guard !isTerminating else { return }

        DebugLog.shared.write("schedule display refresh delay=\(delay) extendFastWindow=\(extendFastWindow)")
        if extendFastWindow {
            beginFastRefreshWindow()
        }
        scheduledRefreshGeneration += 1
        let generation = scheduledRefreshGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.scheduledRefreshGeneration == generation else { return }
            self.refreshAndApplyAutoSwitch()
        }
        configureRefreshTimer()
    }

    private func cancelScheduledRefresh() {
        scheduledRefreshGeneration += 1
    }

    private func refreshAndApplyAutoSwitch() {
        guard !isTerminating else { return }
        guard autoSettings.autoEnabled else {
            DebugLog.shared.write("auto refresh skipped: auto disabled")
            configureRefreshTimer()
            return
        }

        guard !isAutoRefreshInFlight else {
            DebugLog.shared.write("auto refresh queued: in flight")
            autoRefreshQueued = true
            return
        }

        isAutoRefreshInFlight = true
        refreshStatus { [weak self] status in
            guard let self else { return }
            self.isAutoRefreshInFlight = false
            self.applyAutoSwitch(status: status)
            self.configureRefreshTimer()

            if self.autoRefreshQueued {
                self.autoRefreshQueued = false
                self.scheduleDisplayChangeRefresh(after: 0.2, extendFastWindow: false)
            }
        }
    }

    private func refreshStatus(completion: ((DisplayStatus) -> Void)? = nil) {
        guard let helper else {
            lastStatus = DisplayStatus(
                layout: .unknown,
                builtinDisplayID: nil,
                online: nil,
                mirror: nil,
                activeExternalCount: nil,
                physicalExternalCount: nil,
                liveExternalCount: nil,
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
            let result = helper.run(["status"], timeout: 2)
            let status = Self.parseStatus(result.output + result.error)
            DispatchQueue.main.async {
                guard let self else { return }
                if result.exitCode == 0 {
                    self.lastStatus = status
                    self.cacheBuiltinDisplayID(from: status)
                } else {
                    self.lastStatus = DisplayStatus(
                        layout: .unknown,
                        builtinDisplayID: nil,
                        online: nil,
                        mirror: nil,
                        activeExternalCount: nil,
                        physicalExternalCount: nil,
                        liveExternalCount: nil,
                        hardwareExternalKeys: nil,
                        lastHardwareUnplugEvent: nil,
                        lastHardwarePlugEvent: nil,
                        rawText: result.combinedText
                    )
                }
                DebugLog.shared.write("status refresh exit=\(result.exitCode) status=\(self.lastStatus.debugSummary) text=\(result.exitCode == 0 ? "" : Self.abbreviated(result.combinedText))")
                self.updateMenu()
                completion?(self.lastStatus)
            }
        }
    }

    private func applyAutoSwitch(status: DisplayStatus) {
        guard autoSettings.autoEnabled, helper != nil, !isBusy, !isTerminating else {
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
        let newUnplug = newerEvent(status.lastHardwareUnplugEvent, than: lastSeenHardwareUnplugEvent)
        let newPlug = newerEvent(status.lastHardwarePlugEvent, than: lastSeenHardwarePlugEvent)

        if let unplug = newUnplug {
            lastSeenHardwareUnplugEvent = unplug
            pendingRestoreUnplugEvent = unplug
            pendingAutoOffPlugEvent = nil
        }

        if let plug = newPlug {
            lastSeenHardwarePlugEvent = plug
            if let pendingRestore = pendingRestoreUnplugEvent,
               plug > pendingRestore,
               allowedExternalActive(status),
               (status.activeExternalCount ?? 0) > 0 {
                pendingRestoreUnplugEvent = nil
                pendingAutoOffPlugEvent = plug
            }
            if pendingRestoreUnplugEvent == nil {
                pendingAutoOffPlugEvent = plug
            }
        }

        if newUnplug != nil || newPlug != nil {
            beginFastRefreshWindow(duration: hardwareEventRefreshDuration)
        }
    }

    private func newerEvent(_ event: UInt64?, than previous: UInt64?) -> UInt64? {
        guard let event, let previous, event > previous else {
            return nil
        }
        return event
    }

    private func normalizeAutoManagedState(_ status: DisplayStatus) {
        guard status.layout == .disconnected, allowedExternalActive(status) else {
            return
        }
        autoSettings.autoManagedOff = true
    }

    private func handleLostExternalLayout(_ status: DisplayStatus) -> Bool {
        guard status.layout != .connected, externalLinkLost(status) else {
            return false
        }

        DebugLog.shared.write("lost external layout restore status=\(status.debugSummary)")
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
            DebugLog.shared.write("pending restore cleared status=\(status.debugSummary)")
            pendingRestoreUnplugEvent = nil
            pendingAutoOffPlugEvent = nil
            autoSettings.autoManagedOff = false
            return false
        }

        guard status.layout == .disconnected else {
            if externalLinkLost(status) {
                DebugLog.shared.write("pending restore action from uncertain layout status=\(status.debugSummary)")
                runAction(name: text.actionName(layout: .disconnected), arguments: ["on", "--commit", "session"], automatic: true)
                return true
            }

            DebugLog.shared.write("pending restore waiting status=\(status.debugSummary)")
            return true
        }

        DebugLog.shared.write("pending restore action status=\(status.debugSummary)")
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
            DebugLog.shared.write("pending auto off action status=\(status.debugSummary)")
            autoSettings.autoManagedOff = true
            pendingAutoOffPlugEvent = nil
            runAction(name: text.actionName(layout: .connected), arguments: ["off", "--commit", "session"], automatic: true)
            return true
        }

        if status.layout == .disconnected {
            DebugLog.shared.write("pending auto off already disconnected status=\(status.debugSummary)")
            autoSettings.autoManagedOff = true
            pendingAutoOffPlugEvent = nil
        }
        return false
    }

    private func externalLinkLost(_ status: DisplayStatus) -> Bool {
        status.activeExternalCount == 0 || status.liveExternalCount == 0
    }

    private func allowedExternalActive(_ status: DisplayStatus) -> Bool {
        guard (status.liveExternalCount ?? status.physicalExternalCount ?? 0) > 0,
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
                DebugLog.shared.write("CoreGraphics display callback display=\(display) flags=\(flags.rawValue)")
                delegate.scheduleDisplayChangeRefresh(after: 0)
            }
        }, pointer)
    }

    private static func abbreviated(_ text: String, maxLength: Int = 600) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLength else {
            return trimmed
        }
        let end = trimmed.index(trimmed.startIndex, offsetBy: maxLength)
        return String(trimmed[..<end]) + "...<truncated>"
    }

    private static func parseStatus(_ text: String) -> DisplayStatus {
        var layout: LayoutState = .unknown
        var builtinDisplayID: CGDirectDisplayID?
        var online: Bool?
        var mirror: Bool?
        var externalCount: Int?
        var physicalExternalCount: Int?
        var liveExternalCount: Int?
        var hardwareExternalKeys: Set<String>?
        var lastHardwareUnplugEvent: UInt64?
        var lastHardwarePlugEvent: UInt64?

        for line in text.split(separator: "\n") {
            let lineText = String(line)
            let trimmedLine = lineText.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmedLine.hasPrefix("id="), trimmedLine.contains("builtin=yes") {
                if let range = trimmedLine.range(of: "id=") {
                    let tail = trimmedLine[range.upperBound...]
                    let digits = tail.prefix { $0.isNumber }
                    if let id = CGDirectDisplayID(String(digits)), id > 0 {
                        builtinDisplayID = id
                    }
                }
            }

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

                if let range = line.range(of: "live_external_count=") {
                    let tail = line[range.upperBound...]
                    let digits = tail.prefix { $0.isNumber }
                    liveExternalCount = Int(digits)
                }
            } else if line.hasPrefix("hardware:") || line.hasPrefix("probe:") {
                if let range = line.range(of: "physical_external_count=") {
                    let tail = line[range.upperBound...]
                    let digits = tail.prefix { $0.isNumber }
                    physicalExternalCount = Int(digits)
                }

                if let range = line.range(of: "live_external_count=") {
                    let tail = line[range.upperBound...]
                    let digits = tail.prefix { $0.isNumber }
                    liveExternalCount = Int(digits)
                }

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
            builtinDisplayID: builtinDisplayID,
            online: online,
            mirror: mirror,
            activeExternalCount: externalCount,
            physicalExternalCount: physicalExternalCount,
            liveExternalCount: liveExternalCount,
            hardwareExternalKeys: hardwareExternalKeys,
            lastHardwareUnplugEvent: lastHardwareUnplugEvent,
            lastHardwarePlugEvent: lastHardwarePlugEvent,
            rawText: text
        )
    }

    private func updateMenu() {
        let externalCount = lastStatus.liveExternalCount ?? lastStatus.physicalExternalCount ?? lastStatus.activeExternalCount ?? 0
        let helperAvailable = helper != nil
        let statusTitle = text.statusTitle(
            status: lastStatus,
            isBusy: isBusy,
            helperAvailable: helperAvailable
        )

        statusItem.button?.title = ""
        statusItem.button?.toolTip = statusTitle
        statusItem.button?.setAccessibilityLabel(statusTitle)
        statusItem.button?.image = statusIcon(for: lastStatus)
        statusItem.button?.imagePosition = .imageOnly

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
            symbolName = "laptopcomputer"
        case .disconnected:
            symbolName = "laptopcomputer.slash"
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
