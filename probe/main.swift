// axprobe: a small trial of the macOS Accessibility API (AXUIElement).
//
//   axprobe trial --fixture <path to axfixture> --out <folder> [--mode <label>] [--textedit]
//   axprobe ocr <image file>
//
// `trial` starts the fixture program itself, reads its controls, presses a
// button, sets a text field, uses the menu, and compares every result with
// the state file the fixture writes (what the program itself saw).
// It prints one line per check and writes results.json and tree.txt.
// Exit code 0 = every core check passed.

import Cocoa
import ApplicationServices
import Vision

// ---------------- results ----------------

struct Check {
    let name: String
    let status: String   // PASS, FAIL, INFO-PASS, INFO-FAIL, SKIP
    let detail: String
}

var checks: [Check] = []

func record(_ name: String, _ ok: Bool, _ detail: String = "", core: Bool = true) {
    let status = core ? (ok ? "PASS" : "FAIL") : (ok ? "INFO-PASS" : "INFO-FAIL")
    checks.append(Check(name: name, status: status, detail: detail))
    print("[\(status)] \(name)" + (detail.isEmpty ? "" : " : " + detail))
    fflush(stdout)
}

func skip(_ name: String, _ detail: String) {
    checks.append(Check(name: name, status: "SKIP", detail: detail))
    print("[SKIP] \(name) : \(detail)")
    fflush(stdout)
}

// ---------------- AX helpers ----------------

func axName(_ error: AXError) -> String {
    switch error {
    case .success: return "success"
    case .failure: return "failure(-25200)"
    case .illegalArgument: return "illegalArgument(-25201)"
    case .invalidUIElement: return "invalidUIElement(-25202)"
    case .invalidUIElementObserver: return "invalidUIElementObserver(-25203)"
    case .cannotComplete: return "cannotComplete(-25204)"
    case .attributeUnsupported: return "attributeUnsupported(-25205)"
    case .actionUnsupported: return "actionUnsupported(-25206)"
    case .notificationUnsupported: return "notificationUnsupported(-25207)"
    case .notImplemented: return "notImplemented(-25208)"
    case .apiDisabled: return "apiDisabled(-25211)"
    case .noValue: return "noValue(-25212)"
    default: return "AXError(\(error.rawValue))"
    }
}

func copyAttribute(_ element: AXUIElement, _ name: String) -> (value: AnyObject?, error: AXError) {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    return (error == .success ? value : nil, error)
}

func text(_ element: AXUIElement, _ name: String) -> String? {
    return copyAttribute(element, name).value as? String
}

func valueText(_ element: AXUIElement) -> String? {
    let value = copyAttribute(element, kAXValueAttribute as String).value
    if let string = value as? String { return string }
    if let number = value as? NSNumber { return number.stringValue }
    return nil
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    return (copyAttribute(element, kAXChildrenAttribute as String).value as? [AXUIElement]) ?? []
}

func element(_ owner: AXUIElement, _ name: String) -> AXUIElement? {
    guard let value = copyAttribute(owner, name).value else { return nil }
    guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

func actions(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success, let list = names as? [String] else { return [] }
    return list
}

struct Node {
    let element: AXUIElement
    let depth: Int
    let role: String
    let subrole: String
    let identifier: String
    let title: String
    let value: String?
    let actions: [String]

    var line: String {
        var out = String(repeating: "  ", count: depth) + role
        if !subrole.isEmpty { out += "/" + subrole }
        if !identifier.isEmpty { out += " #" + identifier }
        if !title.isEmpty { out += " \"" + title + "\"" }
        if let value = value { out += " =\"" + value.prefix(80) + "\"" }
        if !actions.isEmpty { out += " [" + actions.joined(separator: ",") + "]" }
        return out
    }
}

func walk(_ element: AXUIElement, depth: Int, into nodes: inout [Node]) {
    if nodes.count >= 600 || depth > 14 { return }
    let role = text(element, kAXRoleAttribute as String) ?? "?"
    let subrole = text(element, kAXSubroleAttribute as String) ?? ""
    // The value of a password field is never read.
    let secure = subrole == "AXSecureTextField"
    nodes.append(Node(element: element, depth: depth, role: role, subrole: subrole,
                      identifier: text(element, kAXIdentifierAttribute as String) ?? "",
                      title: text(element, kAXTitleAttribute as String) ?? "",
                      value: secure ? nil : valueText(element),
                      actions: actions(element)))
    for child in children(element) { walk(child, depth: depth + 1, into: &nodes) }
}

func tree(_ root: AXUIElement) -> [Node] {
    var nodes: [Node] = []
    walk(root, depth: 0, into: &nodes)
    return nodes
}

func waitFor(_ seconds: Double, _ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if condition() { return true }
        usleep(150_000)
    }
    return condition()
}

func readState(_ path: String) -> [String: String] {
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
    var state: [String: String] = [:]
    for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
        guard let cut = line.firstIndex(of: "=") else { continue }
        state[String(line[..<cut])] = String(line[line.index(after: cut)...])
    }
    return state
}

func menuTitles(_ app: AXUIElement) -> (titles: [String], error: AXError) {
    let bar = copyAttribute(app, kAXMenuBarAttribute as String)
    guard let value = bar.value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return ([], bar.error) }
    let items = children(value as! AXUIElement)
    return (items.map { text($0, kAXTitleAttribute as String) ?? "" }, .success)
}

/// Find a menu entry by path, e.g. ["Actions", "Increment"]. The menu is not opened on screen.
func menuItem(_ app: AXUIElement, _ path: [String]) -> AXUIElement? {
    guard var current = element(app, kAXMenuBarAttribute as String) else { return nil }
    for name in path {
        var found: AXUIElement?
        for child in children(current) {
            let role = text(child, kAXRoleAttribute as String) ?? ""
            if role == "AXMenu" {
                // A menu bar item holds one AXMenu; look inside it.
                for inner in children(child) where (text(inner, kAXTitleAttribute as String) ?? "") == name { found = inner }
            } else if (text(child, kAXTitleAttribute as String) ?? "") == name {
                found = child
            }
            if found != nil { break }
        }
        guard let next = found else { return nil }
        current = next
    }
    return current
}

// ---------------- OCR (Vision) ----------------

func recognise(_ path: String) -> [String]? {
    guard let image = NSImage(contentsOfFile: path),
          let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    do { try handler.perform([request]) } catch {
        print("ocr: Vision failed: \(error)")
        return nil
    }
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
}

// ---------------- the trial ----------------

func runTrial(fixture: String, out: String, mode: String, withTextEdit: Bool) -> Int32 {
    try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    let statePath = out + "/fixture-state.txt"
    try? FileManager.default.removeItem(atPath: statePath)
    var treeDump = ""

    print("axprobe trial, mode=\(mode), pid=\(getpid()), parent pid=\(getppid())")

    // 1. What macOS says about this process.
    let trusted = AXIsProcessTrusted()
    record("trusted", trusted, "AXIsProcessTrusted() = \(trusted)")
    record("screen-capture-preflight", CGPreflightScreenCaptureAccess(),
           "CGPreflightScreenCaptureAccess() (needed later for OCR of a window)", core: false)

    // 2. Start the fixture ourselves: the process id we own comes from our own launch.
    let process = Process()
    process.executableURL = URL(fileURLWithPath: fixture)
    process.arguments = [statePath]
    do { try process.run() } catch {
        record("fixture-launch", false, "could not start \(fixture): \(error)")
        return finish(out: out, mode: mode, treeDump: treeDump)
    }
    let pid = process.processIdentifier
    defer { if process.isRunning { process.terminate() } }
    let started = waitFor(20) { !readState(statePath).isEmpty }
    record("fixture-launch", started && process.isRunning, "pid \(pid), state file \(started ? "written" : "missing")")

    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 5)

    // 3. The window, through the Accessibility API.
    var windows: [AXUIElement] = []
    var windowError = AXError.failure
    _ = waitFor(20) {
        let result = copyAttribute(app, kAXWindowsAttribute as String)
        windowError = result.error
        windows = (result.value as? [AXUIElement]) ?? []
        return !windows.isEmpty
    }
    record("window-read", !windows.isEmpty, "AXWindows: \(windows.count) window(s), last answer \(axName(windowError))")
    guard let window = windows.first else {
        return finish(out: out, mode: mode, treeDump: treeDump)
    }

    // 4. The control tree.
    var nodes = tree(window)
    treeDump += "== fixture window ==\n" + nodes.map { $0.line }.joined(separator: "\n") + "\n"
    let button = nodes.first { $0.role == "AXButton" && ($0.identifier == "press-button" || $0.title == "Press me") }
    let label = nodes.first { $0.role == "AXStaticText" && ($0.identifier == "count-label" || ($0.value ?? "").hasPrefix("Count:")) }
    let field = nodes.first { $0.role == "AXTextField" && $0.subrole != "AXSecureTextField" }
    let secret = nodes.first { $0.subrole == "AXSecureTextField" }
    record("tree-read", button != nil && label != nil && field != nil,
           "\(nodes.count) nodes; button \(button != nil), label \(label != nil) (\(label?.value ?? "-")), text field \(field != nil)")
    record("password-field-recognised", secret != nil,
           "subrole AXSecureTextField \(secret != nil ? "found; its value is not read" : "not found")")

    // 5. Press the button, then verify twice: by reading again, and by the fixture's own state.
    if let button = button {
        let error = AXUIElementPerformAction(button.element, kAXPressAction as CFString)
        record("press", error == .success, "AXPress on \"\(button.title)\": \(axName(error))")
        var seen = ""
        let reread = waitFor(5) {
            guard let label = label else { return false }
            seen = valueText(label.element) ?? ""
            return seen == "Count: 1"
        }
        record("press-verified-by-reading", reread, "label now reads \"\(seen)\"")
        let truth = waitFor(5) { readState(statePath)["count"] == "1" }
        record("press-verified-by-fixture", truth, "fixture state count=\(readState(statePath)["count"] ?? "?")")
    } else {
        skip("press", "no button found")
    }

    // 6. Replace the content of the text field and read it back.
    if let field = field {
        let wanted = "hello from ax"
        let error = AXUIElementSetAttributeValue(field.element, kAXValueAttribute as CFString, wanted as CFString)
        let back = valueText(field.element) ?? ""
        record("set-text", error == .success && back == wanted, "set: \(axName(error)); read back \"\(back)\"")
        let truth = waitFor(5) { readState(statePath)["field"] == wanted }
        record("set-text-verified-by-fixture", truth, "fixture state field=\"\(readState(statePath)["field"] ?? "?")\"")
    } else {
        skip("set-text", "no text field found")
    }

    // 7. The menu bar: read it, then trigger an entry without opening it on screen.
    let menu = menuTitles(app)
    record("menu-read", menu.titles.contains("Actions"), "menu bar: \(menu.titles) (\(axName(menu.error)))")
    if let entry = menuItem(app, ["Actions", "Increment"]) {
        let before = Int(readState(statePath)["count"] ?? "") ?? -1
        let error = AXUIElementPerformAction(entry, kAXPressAction as CFString)
        let truth = waitFor(5) { (Int(readState(statePath)["count"] ?? "") ?? -1) == before + 1 }
        record("menu-trigger", error == .success && truth,
               "AXPress on Actions > Increment: \(axName(error)); fixture count \(before) -> \(readState(statePath)["count"] ?? "?")")
    } else {
        record("menu-trigger", false, "entry Actions > Increment not found")
    }

    // 8. Keys sent to the program directly (no global key press). Informational.
    if let field = field {
        let focus = AXUIElementSetAttributeValue(field.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        usleep(300_000)
        let before = readState(statePath)["field"] ?? ""
        let source = CGEventSource(stateID: .hidSystemState)
        let characters = Array("k".utf16)
        for down in [true, false] {
            if let event = CGEvent(keyboardEventSource: source, virtualKey: 40, keyDown: down) {
                event.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: characters)
                event.postToPid(pid)
            }
            usleep(50_000)
        }
        var after = before
        let changed = waitFor(3) {
            after = readState(statePath)["field"] ?? ""
            return after != before && after.contains("k")
        }
        record("keys-to-process", changed,
               "focus: \(axName(focus)); fixture active=\(readState(statePath)["active"] ?? "?"); field \"\(before)\" -> \"\(after)\"", core: false)
    }

    // 9. The tree again, after everything.
    nodes = tree(window)
    treeDump += "\n== fixture window, after ==\n" + nodes.map { $0.line }.joined(separator: "\n") + "\n"

    // 10. OCR on a picture of the screen, if the workflow took one. Informational.
    let shot = out + "/screen.png"
    let capture = Process()
    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    capture.arguments = ["-x", shot]
    if (try? capture.run()) != nil {
        capture.waitUntilExit()
        if let lines = recognise(shot) {
            let hit = lines.contains { $0.contains("Press me") } || lines.contains { $0.contains("Count") }
            record("ocr-vision", hit, "\(lines.count) text line(s) from a screen picture; fixture text found: \(hit)", core: false)
            try? lines.joined(separator: "\n").write(toFile: out + "/ocr.txt", atomically: true, encoding: .utf8)
        } else {
            record("ocr-vision", false, "no picture or Vision failed", core: false)
        }
    } else {
        record("ocr-vision", false, "screencapture could not be started", core: false)
    }

    process.terminate()

    if withTextEdit { treeDump += textEdit() }
    return finish(out: out, mode: mode, treeDump: treeDump)
}

/// A real program: TextEdit. Informational only.
func textEdit() -> String {
    var dump = ""
    let bundle = "com.apple.TextEdit"
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = ["-g", "-b", bundle]
    guard (try? open.run()) != nil else {
        record("textedit-launch", false, "could not run open", core: false)
        return dump
    }
    open.waitUntilExit()
    var running: NSRunningApplication?
    _ = waitFor(20) {
        running = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first
        return running != nil
    }
    guard let textEditApp = running else {
        record("textedit-launch", false, "TextEdit did not appear", core: false)
        return dump
    }
    defer { textEditApp.forceTerminate() }
    let pid = textEditApp.processIdentifier
    record("textedit-launch", true, "pid \(pid)", core: false)
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 5)

    var titles: [String] = []
    var menuError = AXError.failure
    _ = waitFor(15) {
        let menu = menuTitles(app)
        titles = menu.titles
        menuError = menu.error
        return titles.contains("File")
    }
    record("textedit-menu-read", titles.contains("File"), "menu bar: \(titles) (\(axName(menuError)))", core: false)

    // File > New, then type into the document through its value.
    if let entry = menuItem(app, ["File", "New"]) {
        let error = AXUIElementPerformAction(entry, kAXPressAction as CFString)
        var area: Node?
        var count = 0
        _ = waitFor(10) {
            let windows = (copyAttribute(app, kAXWindowsAttribute as String).value as? [AXUIElement]) ?? []
            count = windows.count
            for window in windows {
                if let found = tree(window).first(where: { $0.role == "AXTextArea" }) { area = found; return true }
            }
            return false
        }
        record("textedit-new-document", error == .success && area != nil,
               "File > New: \(axName(error)); windows \(count); text area \(area != nil)", core: false)
        if let area = area {
            let wanted = "typed through accessibility"
            let set = AXUIElementSetAttributeValue(area.element, kAXValueAttribute as CFString, wanted as CFString)
            let back = valueText(area.element) ?? ""
            record("textedit-set-text", set == .success && back == wanted, "set: \(axName(set)); read back \"\(back)\"", core: false)
        }
    } else {
        record("textedit-new-document", false, "entry File > New not found", core: false)
    }
    let windows = (copyAttribute(app, kAXWindowsAttribute as String).value as? [AXUIElement]) ?? []
    for window in windows {
        dump += "\n== TextEdit window ==\n" + tree(window).map { $0.line }.joined(separator: "\n") + "\n"
    }
    return dump
}

func finish(out: String, mode: String, treeDump: String) -> Int32 {
    let failed = checks.filter { $0.status == "FAIL" }.count
    let verdict = failed == 0 ? "PASS" : "FAIL"
    print("")
    print("mode \(mode): \(verdict) (\(checks.filter { $0.status == "PASS" }.count) core passed, \(failed) core failed)")
    let payload: [String: Any] = [
        "mode": mode,
        "verdict": verdict,
        "checks": checks.map { ["name": $0.name, "status": $0.status, "detail": $0.detail] }
    ]
    if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: URL(fileURLWithPath: out + "/results.json"))
    }
    try? treeDump.write(toFile: out + "/tree.txt", atomically: true, encoding: .utf8)
    return failed == 0 ? 0 : 1
}

// ---------------- command line ----------------

func option(_ name: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

let command = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
switch command {
case "trial":
    guard let fixture = option("--fixture"), let out = option("--out") else {
        print("usage: axprobe trial --fixture <path> --out <folder> [--mode <label>] [--textedit]")
        exit(2)
    }
    exit(runTrial(fixture: fixture, out: out, mode: option("--mode") ?? "direct",
                  withTextEdit: CommandLine.arguments.contains("--textedit")))
case "ocr":
    guard CommandLine.arguments.count > 2, let lines = recognise(CommandLine.arguments[2]) else {
        print("usage: axprobe ocr <image file>")
        exit(2)
    }
    print(lines.joined(separator: "\n"))
    exit(0)
default:
    print("usage: axprobe trial --fixture <path> --out <folder> [--mode <label>] [--textedit]")
    print("       axprobe ocr <image file>")
    exit(2)
}
