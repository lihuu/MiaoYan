import Cocoa

// MARK: - Vim Mode Types

enum VimEditorMode {
    case insert
    case normal
    case visual
    case visualLine
    case command
}

enum VimPendingOperator {
    case none
    case delete
    case yank
    case change
}

enum VimVisualDirection {
    case left, right, up, down
}

// MARK: - Protocol for Text View Operations

@MainActor
protocol VimTextViewDelegate: AnyObject {
    // Text storage access
    var vimTextStorage: NSTextStorage? { get }
    var vimSelectedRange: NSRange { get }
    func vimSetSelectedRange(_ range: NSRange)

    // Text editing
    func vimShouldChangeText(in range: NSRange, replacementString: String?) -> Bool
    func vimDidChangeText()
    func vimReplaceCharacters(in range: NSRange, with string: String)

    // Cursor movement (NSTextView built-in)
    func vimMoveLeft()
    func vimMoveRight()
    func vimMoveUp()
    func vimMoveDown()
    func vimMoveToBeginningOfLine()
    func vimMoveToEndOfLine()
    func vimMoveToBeginningOfDocument()
    func vimMoveToEndOfDocument()

    // Undo support
    func vimUndo()

    // Caret style
    func vimSetCaretWidth(_ width: CGFloat)
    func vimSetNeedsDisplay()

    // Typing attributes for font calculation
    var vimTypingAttributes: [NSAttributedString.Key: Any] { get }

    // Note operations
    func vimSaveNote()
    func vimCloseWindow()
}

// MARK: - Vim Mode Handler

@MainActor
class VimModeHandler {

    // MARK: - Properties

    weak var delegate: VimTextViewDelegate?

    private(set) var editorMode: VimEditorMode = .normal
    private var pendingOperator: VimPendingOperator = .none
    private var pendingG: Bool = false
    private var pendingR: Character? = nil
    private var visualAnchor: Int = 0
    private var commandBuffer: String = ""

    // Status bar
    private var statusBarView: NSView?
    private var statusBarLabel: NSTextField?
    private weak var statusBarParentView: NSView?

    // MARK: - Initialization

    init(delegate: VimTextViewDelegate? = nil) {
        self.delegate = delegate
    }

    /// Initialize caret style based on current mode (call this when opening a file)
    func initializeCaretStyle() {
        updateCaretStyle()
    }

    // MARK: - Mode Switching

    func enterInsertMode() {
        editorMode = .insert
        pendingOperator = .none
        updateCaretStyle()
    }

    func enterNormalMode() {
        editorMode = .normal
        pendingOperator = .none
        updateCaretStyle()
    }

    func enterVisualMode() {
        editorMode = .visual
        visualAnchor = delegate?.vimSelectedRange.location ?? 0
        updateCaretStyle()
    }

    func enterVisualLineMode() {
        guard let storage = delegate?.vimTextStorage else { return }
        editorMode = .visualLine
        let nsString = storage.string as NSString
        let cursor = delegate?.vimSelectedRange.location ?? 0
        let lineRange = nsString.lineRange(for: NSRange(location: cursor, length: 0))
        visualAnchor = lineRange.location
        delegate?.vimSetSelectedRange(lineRange)
        updateCaretStyle()
    }

    func enterCommandMode() {
        editorMode = .command
        commandBuffer = ""
        updateCaretStyle()
    }

    // MARK: - Caret Style

    private func updateCaretStyle() {
        let blockWidth = blockCaretWidth()
        let width: CGFloat = (editorMode == .normal || editorMode == .visual || editorMode == .visualLine) ? blockWidth : 1
        delegate?.vimSetCaretWidth(width)
        delegate?.vimSetNeedsDisplay()
        updateStatusBar()
    }

    private func blockCaretWidth() -> CGFloat {
        // Prefer current typing attributes
        if let attrFont = delegate?.vimTypingAttributes[.font] as? NSFont {
            let width = "W".size(withAttributes: [.font: attrFont]).width
            return max(6, min(18, width))
        }

        // Fall back to storage font near the caret
        if let storage = delegate?.vimTextStorage, storage.length > 0 {
            let cursor = delegate?.vimSelectedRange.location ?? 0
            let safeIndex = max(0, min(cursor, storage.length - 1))
            if let storageFont = storage.attribute(.font, at: safeIndex, effectiveRange: nil) as? NSFont {
                let width = "W".size(withAttributes: [.font: storageFont]).width
                return max(6, min(18, width))
            }
        }

        // Finally default note font
        let fallbackFont = UserDefaultsManagement.noteFont
        let width = "W".size(withAttributes: [.font: fallbackFont]).width
        return max(6, min(18, width))
    }

    // MARK: - Key Handling

    /// Handle key event in command mode
    /// Returns true if the event was handled
    func handleCommandModeKey(keyCode: UInt16, characters: String?) -> Bool {
        guard editorMode == .command, let chars = characters else { return false }

        // Backspace/Delete to remove last character
        if keyCode == 51 || keyCode == 117 {  // kVK_Delete or kVK_ForwardDelete
            if !commandBuffer.isEmpty {
                commandBuffer.removeLast()
                updateStatusBar()
            }
            return true
        }

        // Enter to execute command
        if keyCode == 36 {  // kVK_Return
            executeCommand(commandBuffer)
            commandBuffer = ""
            enterNormalMode()
            return true
        }

        // Escape to cancel command
        if keyCode == 53 {  // kVK_Escape
            commandBuffer = ""
            enterNormalMode()
            return true
        }

        // Add character to command buffer (letters and numbers)
        if let char = chars.first, char.isLetter || char.isNumber || char == " " {
            commandBuffer.append(char)
            updateStatusBar()
            return true
        }

        return false
    }

    /// Handle key event in visual mode
    /// Returns true if the event was handled
    func handleVisualModeKey(keyCode: UInt16, characters: String?) -> Bool {
        guard editorMode == .visual, keyCode != 53, let chars = characters else { return false }

        let key = chars.lowercased()

        switch key {
        case "h":
            moveVisualSelection(direction: .left)
            return true
        case "j":
            moveVisualSelection(direction: .down)
            return true
        case "k":
            moveVisualSelection(direction: .up)
            return true
        case "l":
            moveVisualSelection(direction: .right)
            return true
        case "y":
            yankVisualSelection()
            return true
        case "d":
            deleteVisualSelection()
            return true
        default:
            return false
        }
    }

    /// Handle key event in visual line mode
    /// Returns true if the event was handled
    func handleVisualLineModeKey(keyCode: UInt16, characters: String?) -> Bool {
        guard editorMode == .visualLine, keyCode != 53, let chars = characters else { return false }

        let key = chars.lowercased()

        switch key {
        case "j":
            moveVisualLineSelection(direction: .down)
            return true
        case "k":
            moveVisualLineSelection(direction: .up)
            return true
        case "y":
            yankVisualLineSelection()
            return true
        case "d":
            deleteVisualLineSelection()
            return true
        default:
            return false
        }
    }

    /// Handle key event in normal mode
    /// Returns true if the event was handled
    func handleNormalModeKey(keyCode: UInt16, characters: String?, isShiftPressed: Bool) -> Bool {
        guard editorMode == .normal, let chars = characters else { return false }

        let key = chars.lowercased()
        let originalKey = chars

        switch key {
        // Basic movement
        case "h":
            delegate?.vimMoveLeft()
            return true
        case "j":
            delegate?.vimMoveDown()
            return true
        case "k":
            delegate?.vimMoveUp()
            return true
        case "l":
            delegate?.vimMoveRight()
            return true

        // Line movement
        case "0":
            delegate?.vimMoveToBeginningOfLine()
            return true
        case "$":
            if pendingOperator != .none {
                handlePendingOperator(withMotion: "$")
                pendingOperator = .none
            } else {
                delegate?.vimMoveToEndOfLine()
            }
            return true
        case "^":
            if pendingOperator != .none {
                handlePendingOperator(withMotion: "^")
                pendingOperator = .none
            } else {
                moveToBeginningOfLineNonWhitespace()
            }
            return true

        // Word movement
        case "w":
            if isShiftPressed {
                if pendingOperator != .none {
                    handlePendingOperator(withMotion: "W")
                    pendingOperator = .none
                } else {
                    moveWordForward(bigWord: true)
                }
            } else {
                if pendingOperator != .none {
                    handlePendingOperator(withMotion: "w")
                    pendingOperator = .none
                } else {
                    moveWordForward(bigWord: false)
                }
            }
            return true
        case "b":
            if isShiftPressed {
                if pendingOperator != .none {
                    handlePendingOperator(withMotion: "B")
                    pendingOperator = .none
                } else {
                    moveWordBackward(bigWord: true)
                }
            } else {
                if pendingOperator != .none {
                    handlePendingOperator(withMotion: "b")
                    pendingOperator = .none
                } else {
                    moveWordBackward(bigWord: false)
                }
            }
            return true

        // File movement
        case "g":
            if isShiftPressed {
                if pendingOperator != .none {
                    handlePendingOperator(withMotion: "G")
                    pendingOperator = .none
                } else {
                    delegate?.vimMoveToEndOfDocument()
                }
            } else {
                if pendingG {
                    delegate?.vimMoveToBeginningOfDocument()
                    pendingG = false
                } else {
                    pendingG = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        self?.pendingG = false
                    }
                }
            }
            return true

        // Enter insert mode
        case "i":
            if isShiftPressed {
                moveToBeginningOfLineNonWhitespace()
                enterInsertMode()
            } else {
                enterInsertMode()
            }
            return true
        case "a":
            if isShiftPressed {
                delegate?.vimMoveToEndOfLine()
                enterInsertMode()
            } else {
                delegate?.vimMoveRight()
                enterInsertMode()
            }
            return true
        case "o":
            if isShiftPressed {
                insertLineAbove()
            } else {
                insertLineBelow()
            }
            return true

        // Delete operations
        case "x":
            deleteCharacterAtCursor()
            return true
        case "d":
            if isShiftPressed {
                deleteToEndOfLine()
            } else {
                if pendingOperator == .delete {
                    deleteCurrentLine()
                    pendingOperator = .none
                } else {
                    pendingOperator = .delete
                }
            }
            return true

        // Yank operations
        case "y":
            if pendingOperator == .yank {
                yankCurrentLine()
                pendingOperator = .none
            } else {
                pendingOperator = .yank
            }
            return true

        // Change operations
        case "c":
            if isShiftPressed {
                changeToEndOfLine()
            } else {
                if pendingOperator == .change {
                    changeCurrentLine()
                    pendingOperator = .none
                } else {
                    pendingOperator = .change
                }
            }
            return true

        // Paste
        case "p":
            if isShiftPressed {
                pasteBeforeCursor()
            } else {
                pasteAfterCursor()
            }
            return true

        // Replace
        case "r":
            pendingR = " "
            return true

        // Undo
        case "u":
            delegate?.vimUndo()
            return true

        // Visual mode
        case "v":
            if isShiftPressed {
                enterVisualLineMode()
            } else {
                enterVisualMode()
            }
            return true

        // Command mode
        case ":":
            enterCommandMode()
            return true

        default:
            // Check for : with original key (since : requires shift)
            if originalKey == ":" {
                enterCommandMode()
                return true
            }

            // Handle replace character
            if pendingR != nil, let char = chars.first {
                replaceCharacterAtCursor(with: char)
                pendingR = nil
                return true
            }

            if pendingOperator != .none {
                NSSound.beep()
                pendingOperator = .none
                return true
            }

            return false
        }
    }

    // MARK: - Status Bar

    func initializeStatusBar(in parentView: NSView?) {
        guard let targetView = parentView else { return }

        if statusBarView == nil {
            let statusBar = NSView()
            statusBar.wantsLayer = true
            statusBar.layer?.backgroundColor = NSColor(calibratedRed: 0.15, green: 0.15, blue: 0.15, alpha: 1.0).cgColor
            statusBarView = statusBar

            let label = NSTextField()
            label.isBordered = false
            label.isBezeled = false
            label.drawsBackground = false
            label.isEditable = false
            label.isSelectable = false
            label.textColor = NSColor.white
            label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            label.stringValue = "NORMAL"
            statusBar.addSubview(label)
            statusBarLabel = label
        }

        guard let statusBar = statusBarView else { return }

        if statusBar.superview == nil {
            targetView.addSubview(statusBar)
            constrainStatusBar(statusBar, to: targetView)
            statusBarParentView = targetView
        }
    }

    private func constrainStatusBar(_ statusBar: NSView, to targetView: NSView) {
        statusBar.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            statusBar.leadingAnchor.constraint(equalTo: targetView.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: targetView.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: targetView.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 24),
        ])

        if let label = statusBarLabel {
            label.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 8),
                label.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            ])
        }
    }

    func updateStatusBar() {
        var modeText = ""
        var modeColor: NSColor = .white

        switch editorMode {
        case .insert:
            modeText = "INSERT"
            modeColor = NSColor.systemGreen
        case .normal:
            modeText = "NORMAL"
            modeColor = NSColor.systemBlue
        case .visual:
            modeText = "VISUAL"
            modeColor = NSColor.systemOrange
        case .visualLine:
            modeText = "VISUAL LINE"
            modeColor = NSColor.systemOrange
        case .command:
            modeText = ":\(commandBuffer)"
            modeColor = NSColor.systemPurple
        }

        statusBarLabel?.stringValue = modeText
        statusBarLabel?.textColor = modeColor
    }

    func hideStatusBar() {
        statusBarView?.removeFromSuperview()
    }
    // MARK: - Command Execution

    private func executeCommand(_ command: String) {
        let trimmedCmd = command.trimmingCharacters(in: .whitespaces).lowercased()

        switch trimmedCmd {
        case "w":
            delegate?.vimSaveNote()
        case "wq", "x":
            delegate?.vimSaveNote()
            delegate?.vimCloseWindow()
        case "q":
            delegate?.vimCloseWindow()
        default:
            NSSound.beep()
        }
    }

    // MARK: - Text Operations

    private func deleteCharacterAtCursor() {
        guard let storage = delegate?.vimTextStorage else { return }
        let cursor = delegate?.vimSelectedRange.location ?? 0
        guard cursor < storage.length else { return }
        let range = NSRange(location: cursor, length: 1)
        if delegate?.vimShouldChangeText(in: range, replacementString: "") == true {
            delegate?.vimReplaceCharacters(in: range, with: "")
            delegate?.vimDidChangeText()
            delegate?.vimSetSelectedRange(NSRange(location: min(cursor, storage.length), length: 0))
        }
    }

    private func deleteCurrentLine() {
        guard let storage = delegate?.vimTextStorage else { return }
        let nsString = storage.string as NSString
        let cursor = delegate?.vimSelectedRange.location ?? 0
        let lineRange = nsString.lineRange(for: NSRange(location: cursor, length: 0))
        if delegate?.vimShouldChangeText(in: lineRange, replacementString: "") == true {
            delegate?.vimReplaceCharacters(in: lineRange, with: "")
            delegate?.vimDidChangeText()
            let newLocation = min(lineRange.location, storage.length)
            delegate?.vimSetSelectedRange(NSRange(location: newLocation, length: 0))
        }
    }

    private func yankCurrentLine() {
        guard let storage = delegate?.vimTextStorage else { return }
        let nsString = storage.string as NSString
        let cursor = delegate?.vimSelectedRange.location ?? 0
        let lineRange = nsString.lineRange(for: NSRange(location: cursor, length: 0))
        let text = nsString.substring(with: lineRange)
        copyToPasteboard(text)
    }

    private func handlePendingOperator(withMotion motion: String) {
        guard let range = motionRange(for: motion) else {
            NSSound.beep()
            return
        }

        switch pendingOperator {
        case .delete:
            applyDelete(range: range)
        case .yank:
            applyYank(range: range)
        case .change:
            applyChange(range: range)
        case .none:
            break
        }
    }

    private func applyChange(range: NSRange) {
        guard let storage = delegate?.vimTextStorage, range.length > 0 else { return }
        if delegate?.vimShouldChangeText(in: range, replacementString: "") == true {
            delegate?.vimReplaceCharacters(in: range, with: "")
            delegate?.vimDidChangeText()
            delegate?.vimSetSelectedRange(NSRange(location: range.location, length: 0))
            enterInsertMode()
        }
    }

    private func motionRange(for motion: String) -> NSRange? {
        guard let storage = delegate?.vimTextStorage else { return nil }
        let nsString = storage.string as NSString
        let cursor = delegate?.vimSelectedRange.location ?? 0
        let length = nsString.length
        guard cursor <= length else { return nil }

        switch motion {
        case "w":
            let target = nextWordBoundary(from: cursor, bigWord: false)
            return target > cursor ? NSRange(location: cursor, length: target - cursor) : nil
        case "W":
            let target = nextWordBoundary(from: cursor, bigWord: true)
            return target > cursor ? NSRange(location: cursor, length: target - cursor) : nil
        case "b":
            let target = previousWordBoundary(from: cursor, bigWord: false)
            return target < cursor ? NSRange(location: target, length: cursor - target) : nil
        case "B":
            let target = previousWordBoundary(from: cursor, bigWord: true)
            return target < cursor ? NSRange(location: target, length: cursor - target) : nil
        case "$":
            let lineRange = nsString.lineRange(for: NSRange(location: min(cursor, max(length - 1, 0)), length: 0))
            var end = lineRange.upperBound
            if end > lineRange.location {
                let ch = nsString.character(at: end - 1)
                if ch == 0x0A || ch == 0x0D {
                    end -= 1
                }
            }
            return end > cursor ? NSRange(location: cursor, length: end - cursor) : nil
        case "^":
            let lineRange = nsString.lineRange(for: NSRange(location: min(cursor, max(length - 1, 0)), length: 0))
            let start = firstNonSpace(in: nsString, range: lineRange)
            return start < cursor ? NSRange(location: start, length: cursor - start) : nil
        case "G":
            let currentLineRange = nsString.lineRange(for: NSRange(location: cursor, length: 0))
            let startPos = currentLineRange.location
            return length > startPos ? NSRange(location: startPos, length: length - startPos) : nil
        default:
            return nil
        }
    }

    private func previousWordBoundary(from index: Int, bigWord: Bool) -> Int {
        guard let storage = delegate?.vimTextStorage else { return index }
        let nsString = storage.string as NSString
        guard index > 0 else { return 0 }

        var i = index - 1

        func isWordChar(_ c: unichar) -> Bool {
            if bigWord {
                return c != 0x20 && c != 0x09 && c != 0x0A && c != 0x0D
            }
            if let scalar = Unicode.Scalar(c) {
                return CharacterSet.alphanumerics.contains(scalar) || c == 95
            }
            return false
        }

        while i > 0 {
            let ch = nsString.character(at: i)
            if ch != 0x20 && ch != 0x09 && ch != 0x0A && ch != 0x0D {
                break
            }
            i -= 1
        }

        let targetIsWord = isWordChar(nsString.character(at: i))
        while i > 0 {
            let ch = nsString.character(at: i - 1)
            if isWordChar(ch) != targetIsWord {
                break
            }
            i -= 1
        }

        return i
    }

    private func nextWordBoundary(from index: Int, bigWord: Bool) -> Int {
        guard let storage = delegate?.vimTextStorage else { return index }
        let nsString = storage.string as NSString
        let length = nsString.length
        var i = index
        guard i < length else { return length }

        func isWordChar(_ c: unichar) -> Bool {
            if bigWord {
                return c != 0x20 && c != 0x09 && c != 0x0A && c != 0x0D
            }
            if let scalar = Unicode.Scalar(c) {
                return CharacterSet.alphanumerics.contains(scalar) || c == 95
            }
            return false
        }

        let currentIsWord = isWordChar(nsString.character(at: i))
        while i < length && isWordChar(nsString.character(at: i)) == currentIsWord {
            i += 1
        }
        while i < length {
            let ch = nsString.character(at: i)
            if ch != 0x20 && ch != 0x09 && ch != 0x0A && ch != 0x0D {
                break
            }
            i += 1
        }
        return i
    }

    private func firstNonSpace(in nsString: NSString, range: NSRange) -> Int {
        let upper = range.location + range.length
        var i = range.location
        while i < upper {
            let ch = nsString.character(at: i)
            if ch != 0x20 && ch != 0x09 && ch != 0x0A && ch != 0x0D {
                return i
            }
            i += 1
        }
        return range.location
    }

    private func applyDelete(range: NSRange) {
        guard let storage = delegate?.vimTextStorage, range.length > 0 else { return }
        if delegate?.vimShouldChangeText(in: range, replacementString: "") == true {
            delegate?.vimReplaceCharacters(in: range, with: "")
            delegate?.vimDidChangeText()
            delegate?.vimSetSelectedRange(NSRange(location: range.location, length: 0))
        }
    }

    private func applyYank(range: NSRange) {
        guard let storage = delegate?.vimTextStorage, range.length > 0 else { return }
        let nsString = storage.string as NSString
        let text = nsString.substring(with: range)
        copyToPasteboard(text)
    }

    private func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.declareTypes([.string], owner: nil)
        pb.setString(text, forType: .string)
    }

    // MARK: - Line Movement

    private func moveToBeginningOfLineNonWhitespace() {
        guard let storage = delegate?.vimTextStorage else { return }
        let nsString = storage.string as NSString
        let cursor = delegate?.vimSelectedRange.location ?? 0
        let lineRange = nsString.lineRange(for: NSRange(location: cursor, length: 0))
        let start = firstNonSpace(in: nsString, range: lineRange)
        delegate?.vimSetSelectedRange(NSRange(location: start, length: 0))
    }

    // MARK: - Word Movement

    private func moveWordForward(bigWord: Bool) {
        guard delegate?.vimTextStorage != nil else { return }
        let cursor = delegate?.vimSelectedRange.location ?? 0
        let target = nextWordBoundary(from: cursor, bigWord: bigWord)
        delegate?.vimSetSelectedRange(NSRange(location: target, length: 0))
    }

    private func moveWordBackward(bigWord: Bool) {
        guard let storage = delegate?.vimTextStorage else { return }
        let nsString = storage.string as NSString
        let cursor = delegate?.vimSelectedRange.location ?? 0
        guard cursor > 0 else { return }

        var i = cursor - 1

        func isWordChar(_ c: unichar) -> Bool {
            if bigWord {
                return c != 0x20 && c != 0x09 && c != 0x0A && c != 0x0D
            }
            if let scalar = Unicode.Scalar(c) {
                return CharacterSet.alphanumerics.contains(scalar) || c == 95
            }
            return false
        }

        while i > 0 {
            let ch = nsString.character(at: i)
            if ch != 0x20 && ch != 0x09 && ch != 0x0A && ch != 0x0D {
                break
            }
            i -= 1
        }

        let targetIsWord = isWordChar(nsString.character(at: i))
        while i > 0 {
            let ch = nsString.character(at: i - 1)
            if isWordChar(ch) != targetIsWord {
                break
            }
            i -= 1
        }

        delegate?.vimSetSelectedRange(NSRange(location: i, length: 0))
    }

    // MARK: - Insert Lines

    private func insertLineBelow() {
        guard let storage = delegate?.vimTextStorage else { return }
        let nsString = storage.string as NSString
        let cursor = delegate?.vimSelectedRange.location ?? 0
        let lineRange = nsString.lineRange(for: NSRange(location: cursor, length: 0))

        var insertPos = lineRange.upperBound
        if insertPos > lineRange.location {
            let ch = nsString.character(at: insertPos - 1)
            if ch == 0x0A || ch == 0x0D {
                insertPos -= 1
            }
        }

        let newLine = "\n"
        let range = NSRange(location: insertPos, length: 0)
        if delegate?.vimShouldChangeText(in: range, replacementString: newLine) == true {
            delegate?.vimReplaceCharacters(in: range, with: newLine)
            delegate?.vimDidChangeText()
            delegate?.vimSetSelectedRange(NSRange(location: insertPos + 1, length: 0))
            enterInsertMode()
        }
    }

    private func insertLineAbove() {
        guard let storage = delegate?.vimTextStorage else { return }
        let nsString = storage.string as NSString
        let cursor = delegate?.vimSelectedRange.location ?? 0
        let lineRange = nsString.lineRange(for: NSRange(location: cursor, length: 0))
        let insertPos = lineRange.location

        let newLine = "\n"
        let range = NSRange(location: insertPos, length: 0)
        if delegate?.vimShouldChangeText(in: range, replacementString: newLine) == true {
            delegate?.vimReplaceCharacters(in: range, with: newLine)
            delegate?.vimDidChangeText()
            delegate?.vimSetSelectedRange(NSRange(location: insertPos, length: 0))
            enterInsertMode()
        }
    }

    // MARK: - Delete Operations

    private func deleteToEndOfLine() {
        guard let storage = delegate?.vimTextStorage else { return }
        let nsString = storage.string as NSString
        let cursor = delegate?.vimSelectedRange.location ?? 0
        let lineRange = nsString.lineRange(for: NSRange(location: cursor, length: 0))
        var end = lineRange.upperBound
        if end > lineRange.location {
            let ch = nsString.character(at: end - 1)
            if ch == 0x0A || ch == 0x0D {
                end -= 1
            }
        }

        if end > cursor {
            let range = NSRange(location: cursor, length: end - cursor)
            if delegate?.vimShouldChangeText(in: range, replacementString: "") == true {
                delegate?.vimReplaceCharacters(in: range, with: "")
                delegate?.vimDidChangeText()
                delegate?.vimSetSelectedRange(NSRange(location: cursor, length: 0))
            }
        }
    }

    // MARK: - Change Operations

    private func changeCurrentLine() {
        guard let storage = delegate?.vimTextStorage else { return }
        let nsString = storage.string as NSString
        let cursor = delegate?.vimSelectedRange.location ?? 0
        let lineRange = nsString.lineRange(for: NSRange(location: cursor, length: 0))

        var indent = ""
        var i = lineRange.location
        let upper = lineRange.location + lineRange.length
        while i < upper {
            let ch = nsString.character(at: i)
            if ch == 0x20 || ch == 0x09 {
                indent.append(Character(UnicodeScalar(ch)!))
                i += 1
            } else {
                break
            }
        }

        let replacement = indent + "\n"
        if delegate?.vimShouldChangeText(in: lineRange, replacementString: replacement) == true {
            delegate?.vimReplaceCharacters(in: lineRange, with: replacement)
            delegate?.vimDidChangeText()
            delegate?.vimSetSelectedRange(NSRange(location: lineRange.location + indent.count, length: 0))
            enterInsertMode()
        }
    }

    private func changeToEndOfLine() {
        deleteToEndOfLine()
        enterInsertMode()
    }

    // MARK: - Paste Operations

    private func pasteAfterCursor() {
        let pb = NSPasteboard.general
        guard let text = pb.string(forType: .string), !text.isEmpty else { return }
        guard let storage = delegate?.vimTextStorage else { return }

        var cursor = delegate?.vimSelectedRange.location ?? 0

        if text.hasSuffix("\n") {
            let nsString = storage.string as NSString
            let lineRange = nsString.lineRange(for: NSRange(location: cursor, length: 0))
            cursor = lineRange.upperBound
        } else {
            cursor = min(cursor + 1, storage.length)
        }

        let range = NSRange(location: cursor, length: 0)
        if delegate?.vimShouldChangeText(in: range, replacementString: text) == true {
            delegate?.vimReplaceCharacters(in: range, with: text)
            delegate?.vimDidChangeText()

            let newPos = text.hasSuffix("\n") ? cursor + text.count - 1 : cursor + text.count - 1
            delegate?.vimSetSelectedRange(NSRange(location: max(cursor, min(newPos, storage.length - 1)), length: 0))
        }
    }

    private func pasteBeforeCursor() {
        let pb = NSPasteboard.general
        guard let text = pb.string(forType: .string), !text.isEmpty else { return }
        guard let storage = delegate?.vimTextStorage else { return }

        var cursor = delegate?.vimSelectedRange.location ?? 0

        if text.hasSuffix("\n") {
            let nsString = storage.string as NSString
            let lineRange = nsString.lineRange(for: NSRange(location: cursor, length: 0))
            cursor = lineRange.location
        }

        let range = NSRange(location: cursor, length: 0)
        if delegate?.vimShouldChangeText(in: range, replacementString: text) == true {
            delegate?.vimReplaceCharacters(in: range, with: text)
            delegate?.vimDidChangeText()

            let newPos = text.hasSuffix("\n") ? cursor + text.count - 1 : cursor + text.count - 1
            delegate?.vimSetSelectedRange(NSRange(location: max(cursor, min(newPos, storage.length - 1)), length: 0))
        }
    }

    // MARK: - Replace Character

    private func replaceCharacterAtCursor(with char: Character) {
        guard let storage = delegate?.vimTextStorage else { return }
        let cursor = delegate?.vimSelectedRange.location ?? 0
        guard cursor < storage.length else { return }

        let replacement = String(char)
        let range = NSRange(location: cursor, length: 1)
        if delegate?.vimShouldChangeText(in: range, replacementString: replacement) == true {
            delegate?.vimReplaceCharacters(in: range, with: replacement)
            delegate?.vimDidChangeText()
            delegate?.vimSetSelectedRange(NSRange(location: cursor, length: 0))
        }
    }

    // MARK: - Visual Mode

    private func moveVisualSelection(direction: VimVisualDirection) {
        guard let storage = delegate?.vimTextStorage else { return }
        let nsString = storage.string as NSString
        let currentRange = delegate?.vimSelectedRange ?? NSRange(location: 0, length: 0)
        var newCursor = currentRange.location + currentRange.length

        switch direction {
        case .left:
            if newCursor > 0 {
                newCursor -= 1
            }
        case .right:
            if newCursor < nsString.length {
                newCursor += 1
            }
        case .up:
            delegate?.vimMoveUp()
            newCursor = delegate?.vimSelectedRange.location ?? 0
        case .down:
            delegate?.vimMoveDown()
            newCursor = delegate?.vimSelectedRange.location ?? 0
        }

        let start = min(visualAnchor, newCursor)
        let end = max(visualAnchor, newCursor)
        delegate?.vimSetSelectedRange(NSRange(location: start, length: end - start))
    }

    private func yankVisualSelection() {
        let range = delegate?.vimSelectedRange ?? NSRange(location: 0, length: 0)
        guard range.length > 0, let storage = delegate?.vimTextStorage else { return }
        let nsString = storage.string as NSString
        let text = nsString.substring(with: range)
        copyToPasteboard(text)
        enterNormalMode()
        delegate?.vimSetSelectedRange(NSRange(location: range.location, length: 0))
    }

    private func deleteVisualSelection() {
        let range = delegate?.vimSelectedRange ?? NSRange(location: 0, length: 0)
        guard range.length > 0 else { return }
        if delegate?.vimShouldChangeText(in: range, replacementString: "") == true {
            delegate?.vimReplaceCharacters(in: range, with: "")
            delegate?.vimDidChangeText()
            enterNormalMode()
            delegate?.vimSetSelectedRange(NSRange(location: range.location, length: 0))
        }
    }

    private func moveVisualLineSelection(direction: VimVisualDirection) {
        guard let storage = delegate?.vimTextStorage else { return }
        let nsString = storage.string as NSString
        let currentRange = delegate?.vimSelectedRange ?? NSRange(location: 0, length: 0)
        var currentLineRange = nsString.lineRange(for: currentRange)

        switch direction {
        case .down:
            let nextLineStart = currentLineRange.upperBound
            if nextLineStart < nsString.length {
                let nextLineRange = nsString.lineRange(for: NSRange(location: nextLineStart, length: 0))
                currentLineRange = NSUnionRange(currentLineRange, nextLineRange)
            }
        case .up:
            if currentLineRange.location > 0 {
                let prevLineStart = currentLineRange.location - 1
                let prevLineRange = nsString.lineRange(for: NSRange(location: prevLineStart, length: 0))
                currentLineRange = NSUnionRange(currentLineRange, prevLineRange)
            }
        default:
            break
        }

        let anchorLineRange = nsString.lineRange(for: NSRange(location: visualAnchor, length: 0))
        let start = min(anchorLineRange.location, currentLineRange.location)
        let end = max(anchorLineRange.upperBound, currentLineRange.upperBound)
        delegate?.vimSetSelectedRange(NSRange(location: start, length: end - start))
    }

    private func yankVisualLineSelection() {
        let range = delegate?.vimSelectedRange ?? NSRange(location: 0, length: 0)
        guard range.length > 0, let storage = delegate?.vimTextStorage else { return }
        let nsString = storage.string as NSString
        let text = nsString.substring(with: range)
        copyToPasteboard(text)
        enterNormalMode()
        let lineStart = nsString.lineRange(for: NSRange(location: range.location, length: 0)).location
        delegate?.vimSetSelectedRange(NSRange(location: lineStart, length: 0))
    }

    private func deleteVisualLineSelection() {
        let range = delegate?.vimSelectedRange ?? NSRange(location: 0, length: 0)
        guard range.length > 0 else { return }
        if delegate?.vimShouldChangeText(in: range, replacementString: "") == true {
            delegate?.vimReplaceCharacters(in: range, with: "")
            delegate?.vimDidChangeText()
            enterNormalMode()
            delegate?.vimSetSelectedRange(NSRange(location: range.location, length: 0))
        }
    }
}
