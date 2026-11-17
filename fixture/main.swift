// A tiny AppKit program used as the test target.
// It writes what really happened to a state file, so a test can compare
// what the Accessibility API reports with what the program itself saw.
//
// Usage: axfixture <state-file>

import Cocoa

final class TableSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let rows: [[String]] = [["Alpha", "1"], ["Beta", "2"], ["Gamma", "3"]]

    func numberOfRows(in tableView: NSTableView) -> Int {
        return rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        var index = 0
        if let column = tableColumn, let found = tableView.tableColumns.firstIndex(of: column) { index = found }
        return NSTextField(labelWithString: rows[row][index])
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let statePath: String
    var window: NSWindow!
    var count = 0
    var lastState = ""
    let label = NSTextField(labelWithString: "Count: 0")
    let field = NSTextField(string: "")
    let secret = NSSecureTextField(string: "")
    let check = NSButton(checkboxWithTitle: "Option", target: nil, action: nil)
    let table = NSTableView()
    let tableSource = TableSource()

    init(statePath: String) {
        self.statePath = statePath
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 200, y: 300, width: 380, height: 400),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "AX Fixture"

        let button = NSButton(title: "Press me", target: self, action: #selector(pressed(_:)))
        button.frame = NSRect(x: 20, y: 350, width: 120, height: 32)
        button.setAccessibilityIdentifier("press-button")

        label.frame = NSRect(x: 160, y: 355, width: 200, height: 22)
        label.setAccessibilityIdentifier("count-label")

        field.frame = NSRect(x: 20, y: 305, width: 340, height: 24)
        field.placeholderString = "Free text"
        field.setAccessibilityIdentifier("text-field")

        secret.frame = NSRect(x: 20, y: 265, width: 340, height: 24)
        secret.placeholderString = "Password"
        secret.setAccessibilityIdentifier("secret-field")

        check.frame = NSRect(x: 20, y: 225, width: 200, height: 24)
        check.setAccessibilityIdentifier("option-check")

        for title in ["Name", "Number"] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(title))
            column.title = title
            column.width = 150
            table.addTableColumn(column)
        }
        table.dataSource = tableSource
        table.delegate = tableSource
        table.setAccessibilityIdentifier("items-table")
        let scroll = NSScrollView(frame: NSRect(x: 20, y: 20, width: 340, height: 190))
        scroll.documentView = table
        scroll.hasVerticalScroller = true

        for view in [button, label, field, secret, check, scroll] as [NSView] {
            window.contentView?.addSubview(view)
        }

        buildMenu()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        writeState()
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.writeState()
        }
    }

    func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let actionsItem = NSMenuItem()
        let actions = NSMenu(title: "Actions")
        let increment = NSMenuItem(title: "Increment", action: #selector(pressed(_:)), keyEquivalent: "i")
        increment.target = self
        actions.addItem(increment)
        let reset = NSMenuItem(title: "Reset", action: #selector(reset(_:)), keyEquivalent: "")
        reset.target = self
        actions.addItem(reset)
        actionsItem.submenu = actions
        main.addItem(actionsItem)

        NSApp.mainMenu = main
    }

    @objc func pressed(_ sender: Any?) {
        count += 1
        label.stringValue = "Count: \(count)"
        writeState()
    }

    @objc func reset(_ sender: Any?) {
        count = 0
        label.stringValue = "Count: 0"
        writeState()
    }

    func writeState() {
        let text = "count=\(count)\n"
            + "field=\(field.stringValue)\n"
            + "secretLength=\(secret.stringValue.count)\n"
            + "check=\(check.state == .on ? 1 : 0)\n"
            + "selectedRow=\(table.selectedRow)\n"
            + "active=\(NSApp.isActive ? 1 : 0)\n"
        if text == lastState { return }
        lastState = text
        try? text.write(toFile: statePath, atomically: true, encoding: .utf8)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

let arguments = CommandLine.arguments
let statePath = arguments.count > 1 ? arguments[1] : NSTemporaryDirectory() + "axfixture-state.txt"
let app = NSApplication.shared
let delegate = AppDelegate(statePath: statePath)
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
