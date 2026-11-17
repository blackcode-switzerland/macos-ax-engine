// axengine: desktop programs on macOS as MCP tools, through the Accessibility
// API (AXUIElement). No screenshots. The loop is read, act, read again to verify.
//
//   axengine mcp        speak MCP (JSON-RPC 2.0, one message per line) on stdin/stdout
//   axengine version
//
// Rules kept in this file:
//   * only windows of programs started by launch_app of THIS server are read or driven;
//   * a program that is already running is never taken over;
//   * password fields are never read and never filled;
//   * browsers, shells, terminals, script runners and system settings are not started;
//   * the Apple menu (shut down, log out) is never listed or triggered.

import Cocoa
import ApplicationServices

typealias JSON = [String: Any]
let engineVersion = "0.1.0"

// ---------------- JSON helpers ----------------

func isBool(_ value: Any?) -> Bool {
    guard let value = value else { return false }
    return CFGetTypeID(value as AnyObject) == CFBooleanGetTypeID()
}
func str(_ object: JSON, _ key: String) -> String? { return object[key] as? String }
func int(_ object: JSON, _ key: String) -> Int? {
    guard let number = object[key] as? NSNumber, !isBool(number) else { return nil }
    let double = number.doubleValue
    return double == double.rounded() ? number.intValue : nil
}
func flag(_ object: JSON, _ key: String) -> Bool {
    return isBool(object[key]) && ((object[key] as? Bool) ?? false)
}
func encode(_ value: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]),
          let text = String(data: data, encoding: .utf8) else { return "{}" }
    return text
}
func quoted(_ text: String) -> String {
    let wrapped = encode([text])
    return String(wrapped.dropFirst().dropLast())
}
func clip(_ text: String, _ count: Int) -> String {
    let flat = text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    return flat.count <= count ? flat : String(flat.prefix(count)) + "…"
}
func refuse(_ reason: String, _ message: String, _ hint: String? = nil) -> JSON {
    var answer: JSON = ["status": "refused", "reason": reason, "message": message]
    if let hint = hint { answer["hint"] = hint }
    return answer
}
func orNull(_ value: Any?) -> Any { return value ?? NSNull() }

// ---------------- Accessibility helpers ----------------

func axName(_ error: AXError) -> String {
    switch error {
    case .success: return "success"
    case .cannotComplete: return "cannotComplete(-25204)"
    case .attributeUnsupported: return "attributeUnsupported(-25205)"
    case .actionUnsupported: return "actionUnsupported(-25206)"
    case .apiDisabled: return "apiDisabled(-25211)"
    case .invalidUIElement: return "invalidUIElement(-25202)"
    default: return "AXError(\(error.rawValue))"
    }
}
func copyAttribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func text(_ element: AXUIElement, _ name: String) -> String? { return copyAttribute(element, name) as? String }
func truth(_ element: AXUIElement, _ name: String) -> Bool? {
    guard let value = copyAttribute(element, name), isBool(value) else { return nil }
    return (value as? Bool) ?? false
}
func valueText(_ element: AXUIElement) -> String? {
    let value = copyAttribute(element, kAXValueAttribute as String)
    if let string = value as? String { return string }
    if let number = value as? NSNumber { return number.stringValue }
    return nil
}
func children(_ element: AXUIElement, _ name: String = kAXChildrenAttribute as String) -> [AXUIElement] {
    return (copyAttribute(element, name) as? [AXUIElement]) ?? []
}
func child(_ owner: AXUIElement, _ name: String) -> AXUIElement? {
    guard let value = copyAttribute(owner, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}
func actionNames(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success, let list = names as? [String] else { return [] }
    return list
}
func settable(_ element: AXUIElement, _ name: String) -> Bool {
    var answer: DarwinBoolean = false
    return AXUIElementIsAttributeSettable(element, name as CFString, &answer) == .success && answer.boolValue
}
func startTime(_ pid: pid_t) -> Int? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
    let started = info.kp_proc.p_un.__p_starttime
    return Int(started.tv_sec) * 1_000_000 + Int(started.tv_usec)
}
func sleepMs(_ ms: Int) { usleep(UInt32(ms) * 1000) }

// ---------------- what may be started ----------------

let refusedNames: Set<String> = [
    "safari", "google chrome", "google chrome canary", "chromium", "firefox", "microsoft edge", "brave browser", "opera",
    "vivaldi", "arc", "tor browser", "duckduckgo", "orion", "zen", "zen browser",
    "terminal", "iterm", "iterm2", "warp", "kitty", "alacritty", "wezterm", "wezterm-gui", "ghostty", "hyper", "console",
    "sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "pwsh", "osascript", "osacompile", "ssh", "sudo", "su", "env",
    "python", "python3", "ruby", "perl", "node", "php", "swift", "open", "launchctl", "xargs", "nohup", "script",
    "script editor", "automator", "shortcuts", "system settings", "system preferences", "keychain access", "passwords",
    "software update", "installer", "migration assistant", "disk utility"
]
let refusedBundles: Set<String> = [
    "com.apple.safari", "com.google.chrome", "org.chromium.chromium", "org.mozilla.firefox", "com.microsoft.edgemac",
    "com.brave.browser", "com.operasoftware.opera", "com.vivaldi.vivaldi", "company.thebrowser.browser",
    "com.apple.terminal", "com.googlecode.iterm2", "dev.warp.warp-stable", "com.apple.scripteditor2", "com.apple.automator",
    "com.apple.shortcuts", "com.apple.systempreferences", "com.apple.keychainaccess", "com.apple.passwords",
    "com.apple.console", "com.apple.installer", "com.apple.diskutility"
]

func launchRefusal(path: String, bundleId: String?) -> String? {
    var name = (path as NSString).lastPathComponent.lowercased()
    if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
    if refusedNames.contains(name) || (bundleId != nil && refusedBundles.contains(bundleId!.lowercased())) {
        return "Browsers, shells, terminals, script runners and system settings are not started by this tool."
    }
    return nil
}

// ---------------- the engine ----------------

final class Owned {
    let pid: pid_t
    let started: Int
    let name: String
    let process: Process?
    init(pid: pid_t, started: Int, name: String, process: Process?) {
        self.pid = pid; self.started = started; self.name = name; self.process = process
    }
    var alive: Bool {
        if let process = process, !process.isRunning { return false }
        return kill(pid, 0) == 0 && startTime(pid) == started
    }
}

final class Window {
    let id: String
    let element: AXUIElement
    let owner: Owned
    init(id: String, element: AXUIElement, owner: Owned) { self.id = id; self.element = element; self.owner = owner }
    var title: String { return text(element, kAXTitleAttribute as String) ?? "" }
}

final class Control {
    let element: AXUIElement
    let role: String
    let name: String
    let value: String?
    let state: String
    let actions: [String]
    let enabled: Bool
    let password: Bool
    init(element: AXUIElement, role: String, name: String, value: String?, state: String, actions: [String], enabled: Bool, password: Bool) {
        self.element = element; self.role = role; self.name = name; self.value = value; self.state = state
        self.actions = actions; self.enabled = enabled; self.password = password
    }
}

final class Capture {
    var controls: [Control] = []
    var text: [String] = []
    var signature: String {
        return controls.map { $0.role + "\u{1}" + $0.name + "\u{1}" + ($0.value ?? "") + "\u{1}" + $0.state }.joined(separator: "\u{2}")
            + "\u{3}" + text.joined(separator: "\u{2}")
    }
    func present(_ wanted: String) -> Bool {
        return text.contains { $0.contains(wanted) } || controls.contains { $0.name.contains(wanted) || ($0.value ?? "").contains(wanted) }
    }
}

final class Snapshot {
    let window: Window
    let capture: Capture
    var used = false
    init(window: Window, capture: Capture) { self.window = window; self.capture = capture }
}

let roleNames: [String: String] = [
    "AXButton": "Button", "AXStaticText": "Text", "AXTextField": "Edit", "AXTextArea": "Document", "AXCheckBox": "CheckBox",
    "AXRadioButton": "RadioButton", "AXPopUpButton": "ComboBox", "AXComboBox": "ComboBox", "AXMenuButton": "MenuButton",
    "AXMenuItem": "MenuItem", "AXLink": "Hyperlink", "AXList": "List", "AXTable": "Table", "AXOutline": "Tree", "AXRow": "Row",
    "AXCell": "Cell", "AXColumn": "Column", "AXSlider": "Slider", "AXImage": "Image", "AXTabGroup": "Tab", "AXGroup": "Group",
    "AXToolbar": "ToolBar", "AXScrollArea": "Pane", "AXScrollBar": "ScrollBar", "AXSplitGroup": "Pane", "AXSheet": "Dialog",
    "AXWindow": "Window", "AXDisclosureTriangle": "Disclosure", "AXProgressIndicator": "ProgressBar", "AXIncrementor": "Spinner",
    "AXHeading": "Text", "AXWebArea": "Document", "AXRadioGroup": "Group", "AXValueIndicator": "Thumb"
]
let layoutRoles: Set<String> = ["AXGroup", "AXScrollArea", "AXSplitGroup", "AXUnknown", "AXLayoutArea", "AXLayoutItem", "AXRadioGroup",
                                "AXSplitter", "AXScrollBar", "AXValueIndicator", "AXColumn", "AXToolbar", "AXTabGroup", "AXGrowArea", "AXMatte", "AXRuler"]

final class Engine {
    var owned: [Owned] = []
    var windows: [Window] = []
    var windowCounter = 0
    var snapshots: [String: Snapshot] = [:]
    var snapshotOrder: [String] = []

    // ---- ownership

    func live() -> [Owned] { return owned.filter { $0.alive } }

    /// The windows of the programs this server started. Ids stay the same for a window while it lives.
    func refreshWindows() -> [Window] {
        var current: [Window] = []
        for owner in live() {
            let app = AXUIElementCreateApplication(owner.pid)
            AXUIElementSetMessagingTimeout(app, 3)
            for element in children(app, kAXWindowsAttribute as String) {
                if let known = windows.first(where: { $0.owner === owner && CFEqual($0.element, element) }) {
                    current.append(known)
                } else {
                    windowCounter += 1
                    current.append(Window(id: "w\(owner.pid)-\(windowCounter)", element: element, owner: owner))
                }
            }
        }
        windows = current
        return current
    }

    func brief(_ list: [Window]) -> [JSON] {
        return list.map { ["id": $0.id, "title": $0.title, "pid": Int($0.owner.pid), "processStarted": $0.owner.started, "process": $0.owner.name] }
    }

    func ownedWindow(_ id: String) -> (Window?, JSON?) {
        if owned.isEmpty {
            return (nil, refuse("not-owned", "This session has not started any program, so no window can be read or driven.",
                                "Start the program with launch_app; only its windows are available."))
        }
        if let window = refreshWindows().first(where: { $0.id == id }) { return (window, nil) }
        return (nil, refuse("window-not-found", "No window with that exact id exists among the programs this session started.",
                            "Window ids come from list_windows or launch_app; a closed dialog loses its id. Windows of other programs are never available."))
    }

    func ownedSnapshot(_ token: String) -> (Snapshot?, JSON?) {
        guard let snapshot = snapshots[token] else {
            return (nil, refuse("unknown-snapshot", "That snapshot was not handed out by this session.",
                                "Read the window with read_tree and use the snapshot and ids it returns."))
        }
        if !snapshot.window.owner.alive || !owned.contains(where: { $0 === snapshot.window.owner }) {
            return (nil, refuse("not-owned", "The program that snapshot came from is no longer owned by this session (it was closed).",
                                "Use list_windows to see what is still open."))
        }
        return (snapshot, nil)
    }

    func retain(_ window: Window, _ capture: Capture) -> String {
        var bytes = [UInt8](repeating: 0, count: 8)
        for index in 0..<bytes.count { bytes[index] = UInt8.random(in: 0...255) }
        let token = "s" + bytes.map { String(format: "%02x", $0) }.joined()
        snapshots[token] = Snapshot(window: window, capture: capture)
        snapshotOrder.append(token)
        while snapshotOrder.count > 256 { snapshots.removeValue(forKey: snapshotOrder.removeFirst()) }
        return token
    }

    // ---- reading

    func capture(_ window: Window) -> Capture {
        let capture = Capture()
        var visited = 0
        walk(window.element, depth: 0, into: capture, visited: &visited, top: true)
        return capture
    }

    func walk(_ element: AXUIElement, depth: Int, into capture: Capture, visited: inout Int, top: Bool = false) {
        visited += 1
        if visited > 3000 || depth > 40 { return }
        let role = text(element, kAXRoleAttribute as String) ?? "AXUnknown"
        if role == "AXMenuBar" || role == "AXMenu" { return }
        if !top { describe(element, role: role, into: capture) }
        for next in children(element) { walk(next, depth: depth + 1, into: capture, visited: &visited) }
    }

    func describe(_ element: AXUIElement, role: String, into capture: Capture) {
        let subrole = text(element, kAXSubroleAttribute as String) ?? ""
        let password = subrole == "AXSecureTextField"
        var name = text(element, kAXTitleAttribute as String) ?? ""
        if name.isEmpty { name = text(element, kAXDescriptionAttribute as String) ?? "" }
        let offered = actionNames(element)
        let press = offered.contains(kAXPressAction as String)
        var value: String? = nil
        var state = ""
        var actions: [String] = []

        switch role {
        case "AXStaticText", "AXHeading":
            let content = valueText(element) ?? name
            if !content.isEmpty { capture.text.append(content) }
            name = content
        case "AXTextField", "AXTextArea", "AXComboBox":
            if !password {
                value = valueText(element) ?? ""
                if settable(element, kAXValueAttribute as String) { actions.append("set-value") }
                if settable(element, kAXFocusedAttribute as String) { actions.append("focus") }
            }
            if name.isEmpty { name = text(element, kAXPlaceholderValueAttribute as String) ?? "" }
        case "AXCheckBox":
            if valueText(element) == "1" { state = "checked" }
            if press { actions.append("toggle") }
        case "AXRadioButton":
            if valueText(element) == "1" { state = "selected" }
            if press { actions.append("select") }
        case "AXDisclosureTriangle":
            let open = valueText(element) == "1"
            if open { state = "expanded" }
            if press { actions.append(open ? "collapse" : "expand") }
        case "AXRow", "AXCell":
            if truth(element, kAXSelectedAttribute as String) == true { state = "selected" }
            if settable(element, kAXSelectedAttribute as String) { actions.append("select") }
            if name.isEmpty {
                name = children(element).compactMap { valueText($0) ?? text($0, kAXTitleAttribute as String) }.first { !$0.isEmpty } ?? ""
            }
        case "AXPopUpButton", "AXSlider", "AXIncrementor", "AXProgressIndicator":
            value = valueText(element)
            if press { actions.append("invoke") }
        default:
            if press { actions.append("invoke") }
            if name.isEmpty {
                switch subrole {
                case "AXCloseButton": name = "Close"
                case "AXMinimizeButton": name = "Minimize"
                case "AXZoomButton", "AXFullScreenButton": name = "Zoom"
                default: break
                }
            }
        }
        if layoutRoles.contains(role) && name.isEmpty && actions.isEmpty { return }
        if (role == "AXImage" || role == "AXUnknown") && name.isEmpty && actions.isEmpty { return }
        let shown = roleNames[role] ?? (role.hasPrefix("AX") ? String(role.dropFirst(2)) : role)
        capture.controls.append(Control(element: element, role: shown, name: name, value: value, state: state, actions: actions,
                                        enabled: truth(element, kAXEnabledAttribute as String) ?? true, password: password))
    }

    func view(_ token: String, offset: Int = 0, limit: Int = 20, structured: Bool = false) -> JSON {
        guard let snapshot = snapshots[token] else { return refuse("unknown-snapshot", "That snapshot is gone.") }
        let controls = snapshot.capture.controls
        let end = min(controls.count, offset + limit)
        var canvas = ""
        var listed: [JSON] = []
        var hints: [String] = []
        if offset < end {
            for index in offset..<end {
                let control = controls[index]
                var line = "#\(index + 1) \(control.role) \(quoted(clip(control.name, 70)))"
                if let value = control.value { line += " =" + quoted(clip(value, 80)) }
                if !control.state.isEmpty { line += " (" + control.state + ")" }
                if !control.enabled { line += " disabled" }
                if control.password { line += " password-field(not automated)" }
                line += " [" + control.actions.joined(separator: ",") + "]\n"
                canvas += line
                if structured {
                    listed.append(["id": index + 1, "role": control.role, "name": control.name, "value": orNull(control.value),
                                   "state": control.state, "actions": control.actions, "enabled": control.enabled,
                                   "password": control.password])
                }
            }
        }
        if end < controls.count { hints.append("More controls: read_tree with this snapshot and offset \(end).") }
        if controls.isEmpty { hints.append("No controls were reported. Try a fresh read; this is a coverage gap, not proof the window has nothing to do.") }
        if offset < end && controls[offset..<end].contains(where: { ($0.value?.count ?? 0) > 80 }) {
            hints.append("A value is clipped. Use read_text with this snapshot and the control's id to read it in full.")
        }
        var answer: JSON = [
            "status": "ok", "target": snapshot.window.id, "title": snapshot.window.title, "snapshot": token,
            "coverage": "provider-reported; completeness unknown", "totalControls": controls.count, "matchingControls": controls.count,
            "offset": offset, "nextOffset": end < controls.count ? end as Any : NSNull() as Any, "canvas": canvas,
            "text": clip(snapshot.capture.text.joined(separator: " | "), 700), "hints": hints
        ]
        if structured { answer["controls"] = listed }
        return answer
    }

    // ---- expectations

    struct Expectation {
        var textPresent: String?
        var gone: String?
        var countRole: String?
        var count = 0
        var window: String?
        var windowGone: String?
        var anyContent: Bool { return textPresent != nil || gone != nil || countRole != nil }
        var anyWindow: Bool { return window != nil || windowGone != nil }
        var any: Bool { return anyContent || anyWindow }
    }

    func expectation(_ args: JSON) -> (Expectation, JSON?) {
        var expect = Expectation()
        expect.textPresent = str(args, "expect_text")
        expect.gone = str(args, "expect_gone")
        expect.window = str(args, "expect_window")
        expect.windowGone = str(args, "expect_window_gone")
        if let spec = str(args, "expect_count") {
            guard let cut = spec.lastIndex(of: "="), cut != spec.startIndex,
                  let number = Int(spec[spec.index(after: cut)...].trimmingCharacters(in: .whitespaces)), number >= 0 else {
                return (expect, refuse("bad-postcondition", "expect_count must read Role=N, e.g. Button=3. Nothing was sent."))
            }
            expect.countRole = spec[..<cut].trimmingCharacters(in: .whitespaces)
            expect.count = number
        }
        for given in [expect.textPresent, expect.gone, expect.window, expect.windowGone] where given != nil && given!.isEmpty {
            return (expect, refuse("empty-postcondition", "An expectation cannot be empty text. Nothing was sent."))
        }
        return (expect, nil)
    }

    /// nil = nothing was asked.
    func evaluate(_ expect: Expectation, _ capture: Capture?) -> (met: Bool?, predicate: [String], evidence: [String]) {
        guard expect.anyContent else { return (nil, [], []) }
        var all = true
        var predicate: [String] = []
        var evidence: [String] = []
        if let wanted = expect.textPresent {
            let ok = capture?.present(wanted) ?? false
            all = all && ok; predicate.append("expected-text-present"); evidence.append("expect-text present=\(ok)")
        }
        if let wanted = expect.gone {
            let ok = !(capture?.present(wanted) ?? false)
            all = all && ok; predicate.append("expected-gone"); evidence.append("expect-gone absent=\(ok)")
        }
        if let role = expect.countRole {
            let actual = capture?.controls.filter { $0.role.lowercased() == role.lowercased() }.count ?? 0
            all = all && actual == expect.count
            predicate.append("expected-count"); evidence.append("expect-count \(role)=\(expect.count) (actual \(actual))")
        }
        return (all, predicate, evidence)
    }

    func evaluateWindows(_ expect: Expectation, budgetMs: Int = 2500) -> (met: Bool?, predicate: [String], evidence: [String]) {
        guard expect.anyWindow else { return (nil, [], []) }
        let end = Date().addingTimeInterval(Double(budgetMs) / 1000)
        var appeared = false, gone = false
        while true {
            let titles = refreshWindows().map { $0.title.lowercased() }
            appeared = expect.window == nil || titles.contains { $0.contains(expect.window!.lowercased()) }
            gone = expect.windowGone == nil || !titles.contains { $0.contains(expect.windowGone!.lowercased()) }
            if (appeared && gone) || Date() >= end { break }
            sleepMs(50)
        }
        var predicate: [String] = []
        var evidence: [String] = []
        if expect.window != nil { predicate.append("expected-window-present"); evidence.append("expect-window present=\(appeared)") }
        if expect.windowGone != nil { predicate.append("expected-window-gone"); evidence.append("expect-window-gone absent=\(gone)") }
        return (appeared && gone, predicate, evidence)
    }

    func verification(_ verified: Bool?, _ predicate: [String], _ evidence: [String], waitMs: Double) -> JSON {
        return ["state": verified == true ? "satisfied" : verified == false ? "not-satisfied" : "unknown",
                "predicate": predicate.isEmpty ? "none" : predicate.joined(separator: " and "),
                "scope": "observed-control-or-text-state and windows of the owned programs; not whole-task completion",
                "evidence": evidence.isEmpty ? "No expectation given" : evidence.joined(separator: "; "),
                "waitMs": waitMs]
    }

    /// Read the window again and check the expectations, polling within a small budget. Sends nothing.
    func checkAfter(_ window: Window, _ expect: Expectation, budgetMs: Int, viewArgs: JSON,
                    extra: ((Capture) -> (Bool?, String, String))? = nil) -> (verified: Bool?, verification: JSON, observation: Any, closed: Bool, capture: Capture?) {
        let started = Date()
        var latest: Capture? = nil
        var closed = false
        var met: (met: Bool?, predicate: [String], evidence: [String]) = (nil, [], [])
        var own: (Bool?, String, String)? = nil
        while true {
            closed = !refreshWindows().contains { $0 === window }
            latest = closed ? nil : capture(window)
            met = evaluate(expect, latest)
            if let extra = extra, let capture = latest { own = extra(capture) }
            let ownDone = own == nil || own!.0 != false
            if closed || ((met.met != false) && ownDone) || Date().timeIntervalSince(started) * 1000 >= Double(budgetMs) { break }
            sleepMs(40)
        }
        let windowCheck = evaluateWindows(expect)
        var verified: Bool? = own?.0
        var predicate: [String] = []
        var evidence: [String] = []
        if let own = own { predicate.append(own.1); evidence.append(own.2) }
        if closed { evidence.append("The acted-on window closed") }
        if closed && expect.anyContent {
            // The window's text is gone with it: expect_gone holds, expected text or counts do not.
            let holds = expect.textPresent == nil && expect.countRole == nil
            verified = holds && verified != false
            predicate += met.predicate
        } else if let content = met.met {
            if verified == false || !content { verified = false } else { verified = true }
            predicate += met.predicate; evidence += met.evidence
        }
        if let windowMet = windowCheck.met {
            if verified == false || !windowMet { verified = false } else { verified = true }
            predicate += windowCheck.predicate; evidence += windowCheck.evidence
        }
        var observation: Any = NSNull()
        if let capture = latest {
            let token = retain(window, capture)
            observation = view(token, limit: int(viewArgs, "limit") ?? 20)
        }
        return (verified, verification(verified, predicate, evidence, waitMs: Date().timeIntervalSince(started) * 1000), observation, closed, latest)
    }

    // ---- tools

    func launchApp(_ args: JSON) -> JSON {
        guard let path = str(args, "path"), !path.isEmpty else { return refuse("missing-path", "launch_app requires path.") }
        let arguments = (args["args"] as? [String]) ?? []
        if let why = launchRefusal(path: path, bundleId: nil) { return refuse("launch-not-allowed", why) }
        var resolved = path
        let manager = FileManager.default
        if !path.contains("/") {
            let bare = path.hasSuffix(".app") ? path : path + ".app"
            for folder in ["/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities"] {
                if manager.fileExists(atPath: folder + "/" + bare) { resolved = folder + "/" + bare; break }
            }
        }
        var isFolder: ObjCBool = false
        guard manager.fileExists(atPath: resolved, isDirectory: &isFolder) else {
            return refuse("launch-failed", "Nothing exists at that path, and no application of that name was found.",
                          "Give the full path of a program, or the name of an application in the Applications folder.")
        }
        let bundle = resolved.hasSuffix(".app") && isFolder.boolValue
        let bundleId = bundle ? Bundle(path: resolved)?.bundleIdentifier : nil
        if let why = launchRefusal(path: resolved, bundleId: bundleId) { return refuse("launch-not-allowed", why) }

        var owner: Owned?
        if bundle {
            if let bundleId = bundleId, !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty {
                return refuse("already-running", "That application is already open. It belongs to the person at this Mac and is not taken over.",
                              "Nothing was started. This tool only drives programs it starts itself.")
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.addsToRecentItems = false
            configuration.arguments = arguments
            final class Box { var app: NSRunningApplication?; var error: Error? }
            let box = Box()
            let done = DispatchSemaphore(value: 0)
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: resolved), configuration: configuration) { app, error in
                box.app = app; box.error = error; done.signal()
            }
            if done.wait(timeout: .now() + 30) == .timedOut { return refuse("launch-failed", "macOS did not answer the request to open that application.") }
            guard let app = box.app else {
                return refuse("launch-failed", "macOS could not open that application: \(box.error?.localizedDescription ?? "no reason given")")
            }
            let pid = app.processIdentifier
            guard let started = startTime(pid) else { return refuse("launch-failed", "The application ended at once.") }
            owner = Owned(pid: pid, started: started, name: app.localizedName ?? (resolved as NSString).lastPathComponent, process: nil)
        } else {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: resolved)
            process.arguments = arguments
            if let cwd = str(args, "cwd") { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
            // stdout of this server carries protocol lines only.
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return refuse("launch-failed", "Could not start the program: \(error.localizedDescription)") }
            let pid = process.processIdentifier
            guard let started = startTime(pid) else { return refuse("launch-failed", "The program ended at once.") }
            owner = Owned(pid: pid, started: started, name: (resolved as NSString).lastPathComponent, process: process)
        }
        guard let launched = owner else { return refuse("launch-failed", "Nothing was started.") }
        owned.append(launched)
        let begin = Date()
        var mine: [Window] = []
        while true {
            mine = refreshWindows().filter { $0.owner === launched }
            if !mine.isEmpty || Date().timeIntervalSince(begin) > 8 || !launched.alive { break }
            sleepMs(100)
        }
        return ["status": "ok", "pid": Int(launched.pid), "processStarted": launched.started, "process": launched.name,
                "processes": live().map { ["pid": Int($0.pid), "processStarted": $0.started] as JSON },
                "desktop": "visible", "alive": launched.alive, "windows": brief(mine),
                "accessibility": AXIsProcessTrusted() ? "granted" : "missing",
                "hint": !AXIsProcessTrusted()
                    ? "The Accessibility permission is missing, so no window can be read. The person must allow the program that started this tool under System Settings > Privacy & Security > Accessibility."
                    : mine.isEmpty ? "The program started but shows no window yet. Call list_windows again in a moment."
                    : "The program is running. read_tree with one of these window ids reads its controls."]
    }

    func listWindows(_ args: JSON) -> JSON {
        let mine = owned.isEmpty ? [] : refreshWindows()
        return ["status": "ok", "windows": brief(mine),
                "owned": live().map { ["pid": Int($0.pid), "processStarted": $0.started] as JSON },
                "hint": owned.isEmpty ? "Nothing has been started yet. launch_app is the only way a window becomes available."
                    : "Only windows of programs this session started are listed, including their dialogs. Read one with read_tree and its exact id."]
    }

    func readTree(_ args: JSON) -> JSON {
        let windowId = str(args, "window"), token = str(args, "snapshot")
        if (windowId == nil) == (token == nil) {
            return refuse("bad-arguments", "Give exactly one of window (fresh read) or snapshot (another page of an earlier read).")
        }
        var answer: JSON
        if let token = token {
            let (snapshot, refusal) = ownedSnapshot(token)
            if snapshot == nil { return refusal! }
            answer = view(token, offset: int(args, "offset") ?? 0, limit: int(args, "limit") ?? 20, structured: flag(args, "structured"))
        } else {
            let (window, refusal) = ownedWindow(windowId!)
            guard let found = window else { return refusal! }
            let fresh = retain(found, capture(found))
            answer = view(fresh, offset: int(args, "offset") ?? 0, limit: int(args, "limit") ?? 20, structured: flag(args, "structured"))
        }
        if flag(args, "include_ocr") || flag(args, "include_vision") {
            answer["ocrSupport"] = "not available in this engine build; the list holds accessibility-tree entries only"
        }
        return answer
    }

    func readText(_ args: JSON) -> JSON {
        let windowId = str(args, "window")
        var token = str(args, "snapshot")
        let id = int(args, "id")
        if (windowId == nil) == (token == nil) {
            return refuse("bad-arguments", "Give exactly one of window (read it now) or snapshot (an earlier read).")
        }
        if id != nil && token == nil { return refuse("bad-arguments", "An id is only meaningful with the snapshot that listed it.") }
        if let windowId = windowId {
            let (window, refusal) = ownedWindow(windowId)
            guard let found = window else { return refusal! }
            token = retain(found, capture(found))
        }
        let (snapshot, refusal) = ownedSnapshot(token!)
        guard let source = snapshot else { return refusal! }
        if let id = id {
            guard id >= 1, id <= source.capture.controls.count else { return refuse("unknown-id", "That id is absent from that snapshot.") }
            let control = source.capture.controls[id - 1]
            return ["status": "ok", "target": source.window.id, "snapshot": token!, "source": "retained-observation", "id": id,
                    "role": control.role, "name": control.name, "value": orNull(control.value), "valueAvailable": control.value != nil,
                    "actions": control.actions, "enabled": control.enabled,
                    "hint": "This is the full value from that read. For the current state, read the window again."]
        }
        let all = source.capture.text
        let offset = int(args, "offset") ?? 0
        let end = min(all.count, offset + (int(args, "limit") ?? 20))
        var lines = ""
        if offset < end { for index in offset..<end { lines += "t\(index + 1) " + quoted(clip(all[index], 100_000)) + "\n" } }
        return ["status": "ok", "target": source.window.id, "snapshot": token!, "source": "retained-observation",
                "scope": "all static text in the observed window, tree order; not one control",
                "totalLines": all.count, "offset": offset, "nextOffset": end < all.count ? end as Any : NSNull() as Any, "text": lines]
    }

    func readCells(_ args: JSON) -> JSON {
        let (snapshot, refusal) = ownedSnapshot(str(args, "snapshot") ?? "")
        guard let source = snapshot else { return refusal! }
        guard let id = int(args, "id"), id >= 1, id <= source.capture.controls.count else {
            return refuse("unknown-id", "That id is absent from that snapshot.")
        }
        let control = source.capture.controls[id - 1]
        let rows = children(control.element, kAXRowsAttribute as String)
        if rows.isEmpty && copyAttribute(control.element, kAXRowsAttribute as String) == nil {
            return refuse("not-a-grid", "This control does not answer by row and column. Controls that do are Table or Tree.")
        }
        let firstRow = int(args, "row") ?? 0, firstColumn = int(args, "column") ?? 0
        let wantRows = int(args, "rows") ?? 10, wantColumns = int(args, "columns") ?? 6
        var totalColumns = children(control.element, kAXColumnsAttribute as String).count
        var out = ""
        if firstRow < rows.count {
            for index in firstRow..<min(rows.count, firstRow + wantRows) {
                let cells = children(rows[index]).map { cell -> String in
                    if let value = valueText(cell), !value.isEmpty { return value }
                    if let title = text(cell, kAXTitleAttribute as String), !title.isEmpty { return title }
                    return children(cell).compactMap { valueText($0) ?? text($0, kAXTitleAttribute as String) }.first { !$0.isEmpty } ?? ""
                }
                totalColumns = max(totalColumns, cells.count)
                let slice = firstColumn < cells.count ? Array(cells[firstColumn..<min(cells.count, firstColumn + wantColumns)]) : []
                out += "row \(index): " + slice.map { quoted($0) }.joined(separator: " | ") + "\n"
            }
        }
        return ["status": "ok", "target": source.window.id, "id": id, "name": control.name, "totalRows": rows.count,
                "totalColumns": totalColumns, "firstRow": firstRow, "firstColumn": firstColumn, "cells": out,
                "hint": "Rows and columns are counted from 0. Empty cells read as \"\". Ask for another block with row and column."]
    }

    /// Why this control cannot take this action; nil when it can.
    func objection(_ control: Control, _ action: String, text: String?) -> JSON? {
        if control.password {
            return refuse("password-field", "This is a password field. This tool never reads or fills password fields. Nothing was sent.",
                          "The person at the Mac must enter it.")
        }
        if !control.enabled { return refuse("disabled", "That control is disabled. Nothing was sent.") }
        if action == "mouse-click" || action == "scroll-up" || action == "scroll-down" {
            if !control.actions.contains(action) {
                return refuse("unsupported-action", "The action \(action) is not available in this engine build. Nothing was sent.",
                              "Use an action listed in the brackets beside the control.")
            }
        }
        if !control.actions.contains(action) {
            return refuse("unsupported-action", "This control does not offer \(action); it offers [\(control.actions.joined(separator: ","))]. Nothing was sent.",
                          "Use only an action listed in the brackets beside the control.")
        }
        if action == "set-value" && text == nil { return refuse("missing-text", "set_text needs text. Nothing was sent.") }
        return nil
    }

    func dispatch(_ control: Control, _ action: String, text: String?) -> AXError {
        switch action {
        case "set-value":
            return AXUIElementSetAttributeValue(control.element, kAXValueAttribute as CFString, (text ?? "") as CFString)
        case "focus":
            return AXUIElementSetAttributeValue(control.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        case "select" where control.role == "Row" || control.role == "Cell":
            return AXUIElementSetAttributeValue(control.element, kAXSelectedAttribute as CFString, kCFBooleanTrue)
        default:
            return AXUIElementPerformAction(control.element, kAXPressAction as CFString)
        }
    }

    /// The control's own state after the action, read from a fresh capture.
    func ownCheck(_ control: Control, _ action: String, text: String?) -> ((Capture) -> (Bool?, String, String))? {
        if action == "invoke" { return nil }
        return { capture in
            guard let now = capture.controls.first(where: { CFEqual($0.element, control.element) }) else {
                return (nil, "control-state", "The control is no longer in the window")
            }
            switch action {
            case "set-value":
                guard let value = now.value else { return (nil, "value-equals-text", "The value cannot be read back") }
                return (value == text, "value-equals-text", "Exact value match=\(value == text)")
            case "toggle":
                return (now.state != control.state, "toggle-state-changed", "state before=\"\(control.state)\" after=\"\(now.state)\"")
            case "select":
                return (now.state == "selected", "selected", "state after=\"\(now.state)\"")
            case "expand":
                return (now.state == "expanded", "expanded", "state after=\"\(now.state)\"")
            case "collapse":
                return (now.state != "expanded", "collapsed", "state after=\"\(now.state)\"")
            case "focus":
                let focused = truth(now.element, kAXFocusedAttribute as String)
                return (focused, "keyboard-focus", "focused=\(focused.map { String($0) } ?? "unknown")")
            default:
                return (nil, "none", "")
            }
        }
    }

    func execute(_ args: JSON, action: String, text: String?) -> JSON {
        let token = str(args, "snapshot") ?? ""
        let (snapshot, refusal) = ownedSnapshot(token)
        guard let source = snapshot else { return refusal! }
        if source.used {
            return refuse("expired-snapshot", "That snapshot already served an action; the window may have changed. Nothing was sent.",
                          "Take the snapshot and ids from the view the last action returned, or read the window again.")
        }
        guard let id = int(args, "id"), id >= 1, id <= source.capture.controls.count else {
            return refuse("unknown-id", "That id is absent from that snapshot. Nothing was sent.")
        }
        let (expect, bad) = expectation(args)
        if let bad = bad { return bad }
        let control = source.capture.controls[id - 1]
        if let no = objection(control, action, text: text) { return no }
        guard refreshWindows().contains(where: { $0 === source.window }) else {
            return refuse("stale-target", "The window that snapshot came from has closed. Nothing was sent.", "Use list_windows.")
        }
        source.used = true
        let began = Date()
        let error = dispatch(control, action, text: text)
        if error != .success {
            return ["status": "outcome-unknown", "reason": "dispatch-error", "message": "macOS answered \(axName(error)) to \(action).",
                    "target": source.window.id, "originalId": id,
                    "hint": "The action may or may not have happened. Read the window again before deciding anything; do not repeat it blindly."]
        }
        let after = checkAfter(source.window, expect, budgetMs: expect.any || action != "invoke" ? 600 : 250, viewArgs: args,
                               extra: ownCheck(control, action, text: text))
        var answer: JSON = [
            "status": "dispatched", "action": action, "originalId": id, "target": source.window.id,
            "verified": orNull(after.verified), "verification": after.verification,
            "treeChanged": after.capture.map { $0.signature != source.capture.signature } ?? true,
            "totalMs": Date().timeIntervalSince(began) * 1000, "windows": brief(refreshWindows()), "observation": after.observation,
            "hint": after.closed ? "The window you acted on has closed, which is normal for OK, Save or Cancel. Choose the next window from windows and read it."
                : after.verified == nil ? "The action was accepted, but the outcome is unverified. Inspect the returned view; do not repeat the action just because verification is unavailable."
                : after.verified == false ? "The expected state was not observed. Read the new view; if the program is still updating, read again before another action."
                : action == "set-value" ? "set_text replaces the field; it does not submit. If the task needs submission, choose a control from the new view."
                : "Here is the updated view. Use its new snapshot for the next action."
        ]
        if after.closed { answer["windowClosed"] = true }
        return answer
    }

    func runSteps(_ args: JSON) -> JSON {
        let token = str(args, "snapshot") ?? ""
        let (snapshot, refusal) = ownedSnapshot(token)
        guard let source = snapshot else { return refusal! }
        if source.used {
            return refuse("expired-snapshot", "That snapshot already served an action. Nothing was sent.",
                          "Take the snapshot and ids from the view the last action returned, or read the window again.")
        }
        guard let steps = args["steps"] as? [JSON] else { return refuse("bad-steps", "steps must be a list of objects.") }
        // Every step is checked before anything is sent.
        var planned: [(id: Int, control: Control, action: String, text: String?, expect: Expectation)] = []
        for (index, step) in steps.enumerated() {
            var action = str(step, "action") ?? "invoke"
            if action == "set_text" { action = "set-value" }
            guard let id = int(step, "id"), id >= 1, id <= source.capture.controls.count else {
                return refuse("bad-steps", "step \(index + 1): that id is absent from the snapshot. Nothing was sent.")
            }
            let (expect, bad) = expectation(step)
            if var bad = bad { bad["message"] = "step \(index + 1): " + (str(bad, "message") ?? ""); return bad }
            let control = source.capture.controls[id - 1]
            if var no = objection(control, action, text: str(step, "text")) {
                no["message"] = "step \(index + 1): " + (str(no, "message") ?? ""); return no
            }
            planned.append((id, control, action, str(step, "text"), expect))
        }
        guard refreshWindows().contains(where: { $0 === source.window }) else {
            return refuse("stale-target", "The window that snapshot came from has closed. Nothing was sent.", "Use list_windows.")
        }
        source.used = true
        var results: [JSON] = []
        var stopped: String? = nil
        var lastObservation: Any = NSNull()
        var allSatisfied = true
        var failed = false
        for (index, step) in planned.enumerated() {
            let error = dispatch(step.control, step.action, text: step.text)
            if error != .success {
                results.append(["step": index + 1, "id": step.id, "action": step.action, "status": "outcome-unknown", "check": "unknown",
                                "evidence": "macOS answered \(axName(error))"])
                stopped = "step \(index + 1) was not accepted (\(axName(error)))"; failed = true
                break
            }
            let after = checkAfter(source.window, step.expect, budgetMs: 600, viewArgs: args, extra: ownCheck(step.control, step.action, text: step.text))
            lastObservation = after.observation
            let state = (after.verification["state"] as? String) ?? "unknown"
            var entry: JSON = ["step": index + 1, "id": step.id, "action": step.action, "status": "dispatched", "check": state,
                               "evidence": orNull(after.verification["evidence"])]
            if after.closed { entry["windowClosed"] = true }
            results.append(entry)
            if after.verified != true { allSatisfied = false }
            if after.verified == false { stopped = "step \(index + 1) was sent but its check was not satisfied"; failed = true; break }
            if after.closed && index + 1 < planned.count { stopped = "the window closed after step \(index + 1)"; break }
        }
        let complete = stopped == nil
        return ["status": complete ? "dispatched" : "stopped", "action": "batch", "target": source.window.id,
                "completed": results.count - (failed ? 1 : 0), "total": planned.count, "stoppedBecause": orNull(stopped),
                "verified": failed ? false as Any : (allSatisfied ? true as Any : NSNull() as Any),
                "verification": ["state": failed ? "not-satisfied" : allSatisfied ? "satisfied" : "unknown"] as JSON,
                "steps": results, "windows": brief(refreshWindows()), "observation": lastObservation,
                "hint": complete ? "Every step was sent. Use the new snapshot in the view for the next action."
                    : "Later steps were NOT sent. Never resend steps that already ran; read the view and decide."]
    }

    // ---- menu

    func menuEntries(_ app: AXUIElement) -> [(path: [String], element: AXUIElement, enabled: Bool, leaf: Bool)] {
        var out: [(path: [String], element: AXUIElement, enabled: Bool, leaf: Bool)] = []
        guard let bar = child(app, kAXMenuBarAttribute as String) else { return out }
        func descend(_ item: AXUIElement, _ path: [String], _ depth: Int) {
            let submenu = children(item).first { (text($0, kAXRoleAttribute as String) ?? "") == "AXMenu" }
            let entries = submenu.map { children($0) } ?? []
            out.append((path, item, truth(item, kAXEnabledAttribute as String) ?? true, entries.isEmpty))
            if depth >= 4 { return }
            for entry in entries {
                let title = text(entry, kAXTitleAttribute as String) ?? ""
                if title.isEmpty { continue }   // separators
                descend(entry, path + [title], depth + 1)
            }
        }
        for (index, top) in children(bar).enumerated() {
            let title = text(top, kAXTitleAttribute as String) ?? ""
            // The Apple menu (first entry) holds shut down, restart and log out: never listed, never triggered.
            if index == 0 || title == "Apple" || title.isEmpty { continue }
            descend(top, [title], 1)
        }
        return out
    }

    func menu(_ args: JSON) -> JSON {
        let (window, refusal) = ownedWindow(str(args, "window") ?? "")
        guard let found = window else { return refusal! }
        let (expect, bad) = expectation(args)
        if let bad = bad { return bad }
        let app = AXUIElementCreateApplication(found.owner.pid)
        AXUIElementSetMessagingTimeout(app, 3)
        let entries = menuEntries(app)
        if entries.isEmpty { return refuse("menu-not-readable", "This program shows no menu bar that can be read.") }
        guard let wanted = str(args, "path") else {
            var listing = ""
            for entry in entries {
                listing += String(repeating: "  ", count: entry.path.count - 1) + (entry.path.last ?? "") + (entry.enabled ? "" : " (disabled)") + "\n"
            }
            return ["status": "ok", "target": found.id, "title": found.title, "entries": entries.count, "menu": listing,
                    "hint": "Trigger an entry with path, levels separated by ' > ', e.g. \"File > Save As…\". Indentation shows the levels."]
        }
        func plain(_ title: String) -> String {
            return title.replacingOccurrences(of: "…", with: "...").trimmingCharacters(in: .whitespaces).lowercased()
        }
        let parts = wanted.components(separatedBy: ">").map { plain($0) }
        let hits = entries.filter { $0.path.map { plain($0) } == parts }
        guard hits.count == 1, let hit = hits.first else {
            return refuse(hits.isEmpty ? "menu-item-not-found" : "ambiguous-menu-item",
                          hits.isEmpty ? "No menu entry has that path. Nothing was sent." : "More than one menu entry has that path. Nothing was sent.",
                          "Call menu without path to see the entries.")
        }
        if !hit.leaf { return refuse("menu-item-not-found", "That path names a submenu, not an entry. Nothing was sent.", "Give the full path to an entry.") }
        if !hit.enabled { return refuse("disabled", "That menu entry is disabled now. Nothing was sent.") }
        let error = AXUIElementPerformAction(hit.element, kAXPressAction as CFString)
        if error != .success {
            return ["status": "outcome-unknown", "reason": "dispatch-error", "message": "macOS answered \(axName(error)).", "target": found.id,
                    "hint": "Read the window again before deciding anything; do not repeat it blindly."]
        }
        sleepMs(120)
        let after = checkAfter(found, expect, budgetMs: 1500, viewArgs: args)
        return ["status": "dispatched", "action": "menu", "item": hit.path.joined(separator: " > "), "target": found.id,
                "verified": orNull(after.verified), "verification": after.verification, "windows": brief(refreshWindows()),
                "observation": after.observation,
                "hint": "The menu entry was triggered. A new dialog shows up under windows; read it with read_tree."]
    }

    // ---- keys

    static let keyCodes: [String: CGKeyCode] = [
        "enter": 36, "return": 36, "tab": 48, "escape": 53, "esc": 53, "space": 49, "backspace": 51, "delete": 117, "insert": 114,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "up": 126, "down": 125, "left": 123, "right": 124,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32,
        "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46
    ]
    static let modifiers: [String: CGEventFlags] = [
        "cmd": .maskCommand, "command": .maskCommand, "ctrl": .maskControl, "control": .maskControl,
        "alt": .maskAlternate, "option": .maskAlternate, "shift": .maskShift
    ]

    func parseKeys(_ keys: String) -> (strokes: [(CGKeyCode, CGEventFlags)], problem: String?) {
        var strokes: [(CGKeyCode, CGEventFlags)] = []
        for chord in keys.lowercased().split(separator: " ") {
            var flags: CGEventFlags = []
            var code: CGKeyCode? = nil
            let parts = chord.split(separator: "+").map { String($0) }
            for (index, part) in parts.enumerated() {
                if index < parts.count - 1 {
                    guard let modifier = Engine.modifiers[part] else { return ([], "'\(part)' is not a modifier; use cmd, ctrl, alt, shift") }
                    flags.insert(modifier)
                } else {
                    guard let key = Engine.keyCodes[part] else { return ([], "'\(part)' is not a known key name") }
                    code = key
                }
            }
            guard let key = code else { return ([], "'\(chord)' names no key") }
            strokes.append((key, flags))
        }
        return (strokes, nil)
    }

    func sendKeys(_ args: JSON) -> JSON {
        if args["keys"] == nil && args["text"] == nil { return refuse("bad-arguments", "Give keys (key names) and/or text (characters to type).") }
        let (window, refusal) = ownedWindow(str(args, "window") ?? "")
        guard let found = window else { return refusal! }
        let (expect, bad) = expectation(args)
        if let bad = bad { return bad }
        let parsed = parseKeys(str(args, "keys") ?? "")
        if let problem = parsed.problem { return refuse("bad-keys", problem + ". Nothing was sent.") }
        // The control with the keyboard focus must not be a password field.
        let app = AXUIElementCreateApplication(found.owner.pid)
        if let focused = child(app, kAXFocusedUIElementAttribute as String),
           (text(focused, kAXSubroleAttribute as String) ?? "") == "AXSecureTextField" {
            return refuse("password-field", "The keyboard focus is in a password field. This tool never fills password fields. Nothing was sent.")
        }
        let pid = found.owner.pid
        let source = CGEventSource(stateID: .hidSystemState)
        func post(_ code: CGKeyCode, _ flags: CGEventFlags, _ characters: [UniChar]?) {
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
                event.flags = flags
                if let characters = characters { event.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: characters) }
                event.postToPid(pid)
                sleepMs(8)
            }
        }
        // Text first, then keys: "type this, then press enter" in one call.
        if let typed = str(args, "text") { for character in typed { post(0, [], Array(String(character).utf16)) } }
        for stroke in parsed.strokes { post(stroke.0, stroke.1, nil) }
        sleepMs(150)
        let after = checkAfter(found, expect, budgetMs: 1500, viewArgs: args)
        let frontmost = NSRunningApplication(processIdentifier: pid)?.isActive ?? false
        return ["status": "dispatched", "action": "keys", "target": found.id, "verified": orNull(after.verified),
                "verification": after.verification, "windows": brief(refreshWindows()), "observation": after.observation,
                "programInFront": frontmost,
                "hint": "Keys were posted to the program only; no global key was pressed. " +
                    (frontmost ? "" : "The program is not in front: on macOS keys to a background program do not always arrive. Check the view. ") +
                    "Prefer a control's own action or the menu tool; the command key is cmd (cmd+s)."]
    }

    func verify(_ args: JSON) -> JSON {
        let (expect, bad) = expectation(args)
        if let bad = bad { return bad }
        if !expect.any {
            return refuse("bad-arguments", "State at least one expectation: expect_text, expect_gone, expect_count, expect_window, expect_window_gone.")
        }
        let (window, refusal) = ownedWindow(str(args, "window") ?? "")
        guard let found = window else { return refusal! }
        let after = checkAfter(found, expect, budgetMs: 500, viewArgs: args)
        return ["status": "ok", "target": found.id, "verified": orNull(after.verified), "verification": after.verification,
                "windows": brief(refreshWindows()), "observation": after.observation,
                "hint": after.verified == true ? "The expected state is there. Nothing was sent."
                    : "The expected state was not seen. Nothing was sent; read the view before deciding what to do."]
    }

    // ---- closing

    func close(_ owner: Owned, force: Bool) -> JSON {
        if !owner.alive {
            owned.removeAll { $0 === owner }
            return ["status": "ok", "pid": Int(owner.pid), "closed": true, "forced": false, "message": "The program had already ended."]
        }
        let app = NSRunningApplication(processIdentifier: owner.pid)
        if app?.terminate() != true { kill(owner.pid, SIGTERM) }
        let end = Date().addingTimeInterval(3)
        while owner.alive && Date() < end { sleepMs(100) }
        var forced = false
        if owner.alive {
            if !force {
                return ["status": "still-running", "pid": Int(owner.pid), "closed": false,
                        "message": "The program did not close when asked. It is probably asking whether to save.",
                        "windows": brief(refreshWindows()),
                        "hint": "Answer its dialog (see windows), or call close_app again with force; unsaved changes are then lost."]
            }
            if app?.forceTerminate() != true { kill(owner.pid, SIGKILL) }
            let hardEnd = Date().addingTimeInterval(3)
            while owner.alive && Date() < hardEnd { sleepMs(100) }
            forced = true
            if owner.alive {
                return ["status": "error", "reason": "close-failed", "pid": Int(owner.pid), "message": "The program could not be ended."]
            }
        }
        owned.removeAll { $0 === owner }
        return ["status": "ok", "pid": Int(owner.pid), "closed": true, "forced": forced]
    }

    func closeApp(_ args: JSON) -> JSON {
        guard let pid = int(args, "pid"), let owner = owned.first(where: { Int($0.pid) == pid }) else {
            return refuse("not-owned", "This session did not start a process with that id. Nothing was closed.",
                          "list_windows shows the process ids this session owns.")
        }
        return close(owner, force: flag(args, "force"))
    }

    func shutdown() {
        for owner in owned {
            let answer = close(owner, force: true)
            if (answer["forced"] as? Bool) == true {
                FileHandle.standardError.write("axengine: FORCED END of \(owner.name) (pid \(owner.pid)): it did not close when asked. Unsaved changes may be lost.\n".data(using: .utf8)!)
            }
        }
    }
}

// ---------------- tool definitions ----------------

struct Tool {
    let name: String
    let description: String
    let schema: JSON
    let readOnly: Bool
    let run: (JSON) -> JSON
}

func sString(_ description: String) -> JSON { return ["type": "string", "description": description] }
func sInt(_ description: String, _ minimum: Int, _ maximum: Int? = nil) -> JSON {
    var schema: JSON = ["type": "integer", "description": description, "minimum": minimum]
    if let maximum = maximum { schema["maximum"] = maximum }
    return schema
}
func sBool(_ description: String) -> JSON { return ["type": "boolean", "description": description] }
func sObject(_ required: [String], _ properties: [(String, JSON)]) -> JSON {
    var props: JSON = [:]
    for (name, type) in properties { props[name] = type }
    var schema: JSON = ["type": "object", "properties": props, "additionalProperties": false]
    if !required.isEmpty { schema["required"] = required }
    return schema
}
let pWindow: (String, JSON) = ("window", sString("Exact window id from list_windows or launch_app. Titles are not accepted."))
let pSnapshot: (String, JSON) = ("snapshot", sString("Snapshot token returned with the ids you read. Ids are valid only with their snapshot."))
let pExpect: [(String, JSON)] = [
    ("expect_text", sString("Check after the action: this text is present in the window (a name, a value or static text).")),
    ("expect_gone", sString("Check after the action: this text is no longer present, e.g. a dialog title.")),
    ("expect_count", sString("Check after the action: Role=N controls of that role exist, e.g. Row=3.")),
    ("expect_window", sString("Check after the action: a window of this program whose title contains this text exists. The natural check for 'this opened a dialog'.")),
    ("expect_window_gone", sString("Check after the action: no window of this program has this text in its title, e.g. the dialog closed."))
]
let pView: [(String, JSON)] = [
    ("limit", sInt("Controls listed in the returned view, default 20. Set it to the size of the window so the next action needs no re-read.", 1, 200)),
    ("include_offscreen", sBool("Also list controls scrolled out of view in the returned view.")),
    ("include_ocr", sBool("Use local OCR for the returned view too. Not available in this engine build."))
]
let actionEnum: [String] = ["invoke", "toggle", "select", "expand", "collapse", "focus", "scroll-up", "scroll-down", "mouse-click"]

let actionSchema: JSON = ["type": "string", "description": "Default invoke (press). Use only an action the brackets offer.", "enum": actionEnum]
let stepActionSchema: JSON = ["type": "string", "description": "Default invoke (press). set_text replaces the content with text.",
                              "enum": ["invoke", "set_text", "set-value"] + Array(actionEnum.dropFirst())]
let clickProperties: [(String, JSON)] = [
    pSnapshot,
    ("id", sInt("Control id from that snapshot.", 1)),
    ("action", actionSchema),
    ("double", sBool("With mouse-click: a double click."))
]
let setTextProperties: [(String, JSON)] = [
    pSnapshot,
    ("id", sInt("Control id from that snapshot.", 1)),
    ("text", sString("The new content, exactly as it should read."))
]
let oneStepProperties: [(String, JSON)] = [
    ("id", sInt("Control id from the snapshot.", 1)),
    ("action", stepActionSchema),
    ("text", sString("For set_text: the new content. An empty string clears.")),
    ("double", sBool("With mouse-click: a double click."))
]
let stepsSchema: JSON = ["type": "array", "minItems": 1, "maxItems": 20,
                         "description": "1 to 20 actions; every id comes from that one snapshot.",
                         "items": sObject(["id"], oneStepProperties + pExpect)]
let stepsProperties: [(String, JSON)] = [pSnapshot, ("steps", stepsSchema)]
let menuProperties: [(String, JSON)] = [
    pWindow,
    ("path", sString("Menu entry to trigger, levels separated by ' > '. Omit to list the menu."))
]
let keysProperties: [(String, JSON)] = [
    pWindow,
    ("keys", sString("Keys separated by spaces, each a key or a combination joined with +, e.g. \"tab tab enter\", \"cmd+s\". Names: enter tab escape space backspace delete home end pageup pagedown up down left right f1 to f12, single letters and digits; modifiers cmd ctrl alt shift.")),
    ("text", sString("Text to type as characters into the focused control."))
]
let verifyProperties: [(String, JSON)] = [pWindow]
let launchArgsSchema: JSON = ["type": "array", "items": ["type": "string"] as JSON, "description": "Command-line arguments, one per entry."]

func defineTools(_ engine: Engine) -> [Tool] {
    var tools: [Tool] = []
    func add(_ name: String, _ description: String, _ schema: JSON, readOnly: Bool = false, _ run: @escaping (JSON) -> JSON) {
        tools.append(Tool(name: name, description: description, schema: schema, readOnly: readOnly, run: run))
    }
    add("launch_app",
        "Start a program and take ownership of it. This is the only way a window becomes readable or drivable: " +
        "every other tool refuses windows of programs this session did not start. A program that is already open is not taken over. " +
        "Returns the process id and its windows.",
        sObject(["path"], [
            ("path", sString("Program to start: a full path (an .app bundle or an executable), or the name of an application in the Applications folder (e.g. TextEdit).")),
            ("args", launchArgsSchema),
            ("cwd", sString("Working directory for the program."))]),
        engine.launchApp)
    add("list_windows",
        "List the windows of the programs this session started, including their dialogs. Other windows on the computer are never listed.",
        sObject([], []), readOnly: true, engine.listWindows)
    add("read_tree",
        "Read the controls of one owned window as text lines '#id Role \"name\" =\"value\" [actions]', with a snapshot token. " +
        "Give window for a fresh read, or snapshot to page an earlier read. No screenshot is taken. " +
        "A line can also carry (checked), (selected) or (expanded) for the control's state, " +
        "and password-field(not automated) [] for a field this tool never fills or reads.",
        sObject([], [pWindow, pSnapshot,
            ("offset", sInt("First control to list (paging).", 0)),
            ("limit", sInt("Controls per page, default 20.", 1, 200)),
            ("include_offscreen", sBool("Also list controls scrolled out of view.")),
            ("activate", sBool("Fresh read only: bring the window to the front first. Not used by this engine build; windows are read where they are.")),
            ("include_ocr", sBool("Also list text found by local OCR. Not available in this engine build.")),
            ("structured", sBool("Also return the listed controls as data (id, role, name, value, state, actions). For programs, not needed by a model.")),
            ("include_vision", sBool("Also ask a local element detector. Not available in this engine build."))]),
        engine.readTree)
    add("read_text",
        "Read text in full, not clipped. With snapshot and id: the whole value of that field or document. " +
        "With snapshot or window alone: every static text line of the window, paged.",
        sObject([], [pWindow, pSnapshot,
            ("id", sInt("Control id from that snapshot, to read its full value.", 1)),
            ("offset", sInt("First text line (paging).", 0)),
            ("limit", sInt("Lines per page, default 20.", 1, 200))]),
        readOnly: true, engine.readText)
    add("read_cells",
        "Read a block of cells from a table or tree, exactly and for every column (the tree lines name a row by its first column only). " +
        "Rows and columns are counted from 0. Sends nothing.",
        sObject(["snapshot", "id"], [pSnapshot,
            ("id", sInt("Id of the Table or Tree control in that snapshot.", 1)),
            ("row", sInt("First row, default 0.", 0)), ("column", sInt("First column, default 0.", 0)),
            ("rows", sInt("How many rows, default 10.", 1, 50)), ("columns", sInt("How many columns, default 6.", 1, 26))]),
        readOnly: true, engine.readCells)
    add("click",
        "Act on one control by id through its own interface (no mouse movement): press, toggle, select, expand or collapse. " +
        "Use only an action listed in the brackets beside the control. The answer carries the check result and the new view; " +
        "an unknown or not-satisfied result is never a reason to repeat the action blindly. " +
        "A snapshot serves ONE action: take the next ids from the returned view, or use run_steps for several actions on one view.",
        sObject(["snapshot", "id"], clickProperties + pExpect + pView),
        { args in
            if flag(args, "double") && (str(args, "action") ?? "invoke") != "mouse-click" {
                return refuse("bad-arguments", "double only goes with the action mouse-click.")
            }
            return engine.execute(args, action: str(args, "action") ?? "invoke", text: nil)
        })
    add("set_text",
        "Replace the whole content of a field or document, then read it back exactly. It never appends and never submits. An empty string clears. " +
        "A snapshot serves ONE action; to fill several fields of one view use run_steps.",
        sObject(["snapshot", "id", "text"], setTextProperties + pExpect + pView),
        { args in engine.execute(args, action: "set-value", text: str(args, "text")) })
    add("run_steps",
        "Several actions on controls of ONE snapshot in one call, in order, each with its own check. Use it to fill a form and press OK in one call. " +
        "Every step is checked before anything is sent: one invalid step refuses the whole call and nothing happens. " +
        "It stops at the first step that fails or closes the window; later steps are then NOT sent, and the answer (status stopped) " +
        "still lists what ran and the current view. Never resend steps that already ran.",
        sObject(["snapshot", "steps"], stepsProperties + pView),
        engine.runSteps)
    add("menu",
        "Menu bar of the program that owns the window. Without path: the menu as a tree. With path: trigger that entry, e.g. \"File > Save As...\". " +
        "The menu is not opened on screen. The Apple menu is never available.",
        sObject(["window"], menuProperties + pExpect + pView),
        engine.menu)
    add("send_keys",
        "When a control offers no action and the menu tool does not reach it: post keys to the program that owns the window, to the control " +
        "that has the keyboard focus. No global key is pressed. Key combinations work (cmd+s, shift+tab). " +
        "Prefer a control's own action or the menu tool when they exist.",
        sObject(["window"], keysProperties + pExpect + pView),
        engine.sendKeys)
    add("verify",
        "Read an owned window again and check expectations without acting. Answers satisfied, not-satisfied or unknown.",
        sObject(["window"], verifyProperties + pExpect + pView), readOnly: true, engine.verify)
    add("close_app",
        "Close a program this session started, by process id. Processes this session did not start are refused. " +
        "If the answer is still-running the program is probably asking whether to save: answer its dialog, or close again with force.",
        sObject(["pid"], [("pid", sInt("Process id returned by launch_app.", 1)),
                          ("force", sBool("End the program if it does not close when asked. Unsaved changes are lost."))]),
        engine.closeApp)
    return tools
}

/// Check arguments against the tool's own schema. nil when they fit.
func invalid(_ schema: JSON, _ args: JSON) -> String? {
    let properties = (schema["properties"] as? JSON) ?? [:]
    for (key, value) in args {
        guard let expected = properties[key] as? JSON else {
            return "unknown argument '\(key)'; accepted: " + properties.keys.sorted().joined(separator: ", ")
        }
        switch (expected["type"] as? String) ?? "" {
        case "string":
            guard let given = value as? String else { return "'\(key)' must be a string" }
            if let allowed = expected["enum"] as? [String], !allowed.contains(given) {
                return "'\(key)' must be one of: " + allowed.joined(separator: ", ")
            }
        case "boolean":
            if !isBool(value) { return "'\(key)' must be true or false" }
        case "integer":
            guard let number = int(args, key) else { return "'\(key)' must be a whole number" }
            if let minimum = expected["minimum"] as? Int, number < minimum { return "'\(key)' must be at least \(minimum)" }
            if let maximum = expected["maximum"] as? Int, number > maximum { return "'\(key)' must be at most \(maximum)" }
        case "array":
            guard let items = value as? [Any] else { return "'\(key)' must be a list" }
            if let minimum = expected["minItems"] as? Int, items.count < minimum { return "'\(key)' needs at least \(minimum) entry" }
            if let maximum = expected["maxItems"] as? Int, items.count > maximum { return "'\(key)' takes at most \(maximum) entries" }
            let each = (expected["items"] as? JSON) ?? [:]
            if (each["type"] as? String) == "object" {
                for (index, item) in items.enumerated() {
                    guard let object = item as? JSON else { return "'\(key)' entry \(index + 1) must be an object" }
                    if let inner = invalid(each, object) { return "'\(key)' entry \(index + 1): " + inner }
                }
            } else if items.contains(where: { !($0 is String) }) {
                return "'\(key)' must be a list of strings"
            }
        default: break
        }
    }
    for name in (schema["required"] as? [String]) ?? [] where args[name] == nil {
        return "missing required argument '\(name)'"
    }
    return nil
}

// ---------------- MCP over stdio ----------------

func runMcp() {
    let engine = Engine()
    let tools = defineTools(engine)
    let versions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    func reply(_ id: Any?, _ result: Any) -> String { return encode(["jsonrpc": "2.0", "id": orNull(id), "result": result]) }
    func failure(_ id: Any?, _ code: Int, _ message: String) -> String {
        return encode(["jsonrpc": "2.0", "id": orNull(id), "error": ["code": code, "message": message] as JSON])
    }
    func handle(_ line: String) -> String? {
        guard let data = line.data(using: .utf8), let parsed = try? JSONSerialization.jsonObject(with: data) else {
            return failure(nil, -32700, "Parse error")
        }
        guard let message = parsed as? JSON else { return failure(nil, -32600, "Invalid request: one JSON-RPC object per line") }
        let id = message["id"]
        guard let method = message["method"] as? String else {
            if message["result"] != nil || message["error"] != nil { return nil }
            return failure(id, -32600, "Invalid request: method is required")
        }
        if id == nil { return nil }   // a notification
        let params = (message["params"] as? JSON) ?? [:]
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String
            return reply(id, [
                "protocolVersion": asked != nil && versions.contains(asked!) ? asked! : versions[0],
                "capabilities": ["tools": [:] as JSON] as JSON,
                "serverInfo": ["name": "ax-desktop", "version": engineVersion] as JSON,
                "instructions": "Drives macOS desktop programs through their accessibility tree, without screenshots. " +
                    "Loop: launch_app, read_tree, act on one control (click, set_text, menu), then check the returned view. " +
                    "Only programs started with launch_app can be read or driven. Ids belong to the snapshot that listed them. " +
                    "A check result of unknown or not-satisfied means read again, never repeat the action blindly."
            ] as JSON)
        case "ping":
            return reply(id, [:] as JSON)
        case "tools/list":
            return reply(id, ["tools": tools.map { tool -> JSON in
                var entry: JSON = ["name": tool.name, "description": tool.description, "inputSchema": tool.schema]
                if tool.readOnly { entry["annotations"] = ["readOnlyHint": true] as JSON }
                return entry
            }] as JSON)
        case "tools/call":
            guard let name = params["name"] as? String, let tool = tools.first(where: { $0.name == name }) else {
                return failure(id, -32602, "Unknown tool: \((params["name"] as? String) ?? "(none)")")
            }
            if let raw = params["arguments"], !(raw is NSNull), !(raw is JSON) { return failure(id, -32602, "arguments must be an object") }
            let args = (params["arguments"] as? JSON) ?? [:]
            var body: JSON
            if let problem = invalid(tool.schema, args) {
                body = refuse("bad-arguments", problem, "Nothing was sent. Correct the arguments and call \(tool.name) again.")
            } else {
                body = tool.run(args)
            }
            let status = (body["status"] as? String) ?? ""
            return reply(id, ["content": [["type": "text", "text": encode(body)] as JSON],
                              "isError": status != "ok" && status != "dispatched"] as JSON)
        default:
            return failure(id, -32601, "Method not found: \(method)")
        }
    }

    while let line = readLine(strippingNewline: true) {
        if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
        guard let response = handle(line) else { continue }
        print(response)
        fflush(stdout)
    }
    // The client is gone: close what this server started, and only that.
    engine.shutdown()
}

switch CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "" {
case "mcp":
    runMcp()
case "version":
    print("axengine \(engineVersion)")
default:
    print("usage: axengine mcp | axengine version")
    exit(2)
}
