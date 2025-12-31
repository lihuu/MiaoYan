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

    // Count prefix for commands (e.g., 5j means move down 5 lines)
    private var countPrefix: Int = 0

    // Accelerated key repeat for j/k
    private var lastJKKeyTime: Date?
    private var jkRepeatCount: Int = 0
    private let jkAccelerationThreshold: TimeInterval = 0.15  // Time between key presses to consider as repeat
    private let jkBaseAcceleration: Int = 1  // Base movement
    private let jkMaxAcceleration: Int = 5  // Maximum acceleration multiplier

    // f/F/t/T character search
    private var pendingF: Bool = false  // Waiting for character after f
    private var pendingFReverse: Bool = false  // Waiting for character after F
    private var lastFChar: Character? = nil  // Last searched character for ; and ,
    private var lastFWasForward: Bool = true  // Direction of last f/F search

    // Search state for / ? * #
    private var searchPattern: String = ""
    private var searchForward: Bool = true  // true for / and *, false for ? and #

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
        countPrefix = 0
        resetAcceleration()
        updateCaretStyle()
    }

    func enterNormalMode() {
        editorMode = .normal
        pendingOperator = .none
        countPrefix = 0
        resetAcceleration()
        updateCaretStyle()
    }

    func enterVisualMode() {
        editorMode = .visual
        visualAnchor = delegate?.vimSelectedRange.location ?? 0
        countPrefix = 0
        resetAcceleration()
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
        countPrefix = 0
        resetAcceleration()
        updateCaretStyle()
    }

    func enterCommandMode() {
        editorMode = .command
        commandBuffer = ""
        countPrefix = 0
        resetAcceleration()
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

    // MARK: - Accelerated Movement

    /// Calculate accelerated move count for j/k keys when held down
    private func calculateAcceleratedMove(baseCount: Int, forKey key: String) -> Int {
        let now = Date()

        // Check if this is a rapid key repeat
        if let lastTime = lastJKKeyTime {
            let timeSinceLastPress = now.timeIntervalSince(lastTime)

            if timeSinceLastPress < jkAccelerationThreshold {
                // This is a repeat, increase acceleration
                jkRepeatCount += 1
            } else {
                // Too much time passed, reset acceleration
                jkRepeatCount = 0
            }
        } else {
            jkRepeatCount = 0
        }

        lastJKKeyTime = now

        // Calculate acceleration multiplier based on repeat count
        // Ramp up: 1, 1, 2, 2, 3, 3, 4, 4, 5, 5...
        let accelerationLevel = min(jkRepeatCount / 2, jkMaxAcceleration - jkBaseAcceleration)
        let accelerationMultiplier = jkBaseAcceleration + accelerationLevel

        return baseCount * accelerationMultiplier
    }

    /// Reset acceleration state (call when switching modes or other operations)
    private func resetAcceleration() {
        lastJKKeyTime = nil
        jkRepeatCount = 0
    }

    // MARK: - Key Handling

    /// Handle key event in command mode
    /// Returns true if the event was handled
    func handleCommandModeKey(keyCode: UInt16, characters: String?) -> Bool {
        guard editorMode == .command, let chars = characters else { return false }

        // Check if we're in search mode (command starts with / or ?)
        let isSearchMode = commandBuffer.hasPrefix("/") || commandBuffer.hasPrefix("?")

        // Backspace/Delete to remove last character
        if keyCode == 51 || keyCode == 117 {  // kVK_Delete or kVK_ForwardDelete
            if commandBuffer.count > 1 {
                commandBuffer.removeLast()
                updateStatusBar()
            } else if commandBuffer.count == 1 {
                // If only / or ? or : left, cancel
                commandBuffer = ""
                enterNormalMode()
            }
            return true
        }

        // Enter to execute command
        if keyCode == 36 {  // kVK_Return
            if isSearchMode {
                // Execute search
                let pattern = String(commandBuffer.dropFirst())  // Remove / or ?
                if !pattern.isEmpty {
                    searchPattern = pattern
                    findNextSearchResult(forward: true)
                }
            } else {
                executeCommand(commandBuffer)
            }
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

        // Add character to command buffer
        if let char = chars.first {
            if isSearchMode {
                // In search mode, allow any printable character
                if char.isLetter || char.isNumber || char == " " || char.isPunctuation || char.isSymbol {
                    commandBuffer.append(char)
                    updateStatusBar()
                    return true
                }
            } else {
                // In command mode, only letters and numbers
                if char.isLetter || char.isNumber || char == " " {
                    commandBuffer.append(char)
                    updateStatusBar()
                    return true
                }
            }
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

        // Handle digit keys for count prefix (1-9 start count, 0 can continue count or move to beginning)
        if let digit = Int(key), digit >= 1 && digit <= 9 {
            countPrefix = countPrefix * 10 + digit
            updateStatusBar()
            return true
        }

        // Special handling for 0: if we have a count prefix, it's part of the number; otherwise it's move to beginning
        if key == "0" {
            if countPrefix > 0 {
                countPrefix = countPrefix * 10
                updateStatusBar()
                return true
            } else {
                delegate?.vimMoveToBeginningOfLine()
                return true
            }
        }

        // Get the effective count (use countPrefix if set, otherwise 1)
        let count = countPrefix > 0 ? countPrefix : 1

        // Reset count prefix after using it (will be reset at end of switch for commands that use it)
        defer {
            // Reset count prefix after command execution (except for incomplete commands)
            if pendingOperator == .none && !pendingG {
                countPrefix = 0
                updateStatusBar()
            }
        }

        switch key {
        // Basic movement
        case "h":
            for _ in 0..<count {
                delegate?.vimMoveLeft()
            }
            return true
        case "j":
            if isShiftPressed {
                // J - Join lines
                joinLines()
            } else {
                let moveCount = calculateAcceleratedMove(baseCount: count, forKey: "j")
                for _ in 0..<moveCount {
                    delegate?.vimMoveDown()
                }
            }
            return true
        case "k":
            let moveCount = calculateAcceleratedMove(baseCount: count, forKey: "k")
            for _ in 0..<moveCount {
                delegate?.vimMoveUp()
            }
            return true
        case "l":
            for _ in 0..<count {
                delegate?.vimMoveRight()
            }
            return true

        // Line movement (0 handled above)
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

        // Word end movement
        case "e":
            if isShiftPressed {
                moveToEndOfWord(bigWord: true)
            } else {
                moveToEndOfWord(bigWord: false)
            }
            return true

        // Find character on line
        case "f":
            if isShiftPressed {
                pendingFReverse = true
            } else {
                pendingF = true
            }
            return true

        // Search current word
        case "*":
            searchCurrentWord(forward: true)
            return true

        case "#":
            searchCurrentWord(forward: false)
            return true

        // Search mode
        case "/":
            enterSearchMode(forward: true)
            return true

        case "?":
            enterSearchMode(forward: false)
            return true

        // Next/previous search result
        case "n":
            if isShiftPressed {
                findNextSearchResult(forward: false)
            } else {
                findNextSearchResult(forward: true)
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

            // Handle f/F character search
            if pendingF, let char = chars.first {
                findCharacterOnLine(char, forward: true)
                pendingF = false
                return true
            }
            if pendingFReverse, let char = chars.first {
                findCharacterOnLine(char, forward: false)
                pendingFReverse = false
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
            // Show count prefix if any
            if countPrefix > 0 {
                modeText = "NORMAL \(countPrefix)"
            } else {
                modeText = "NORMAL"
            }
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

    /// Move to end of word (e/E command)
    private func moveToEndOfWord(bigWord: Bool) {
        guard let storage = delegate?.vimTextStorage else { return }
        let nsString = storage.string as NSString
        let length = nsString.length
        let cursor = delegate?.vimSelectedRange.location ?? 0
        guard cursor < length else { return }

        var i = cursor

        func isWordChar(_ c: unichar) -> Bool {
            if bigWord {
                return c != 0x20 && c != 0x09 && c != 0x0A && c != 0x0D
            }
            if let scalar = Unicode.Scalar(c) {
                return CharacterSet.alphanumerics.contains(scalar) || c == 95
            }
            return false
        }

        // If currently on a word character, move forward one to start searching
        if i < length - 1 {
            i += 1
        }

        // Skip whitespace
        while i < length {
            let ch = nsString.character(at: i)
            if ch != 0x20 && ch != 0x09 && ch != 0x0A && ch != 0x0D {
                break
            }
            i += 1
        }

        guard i < length else {
            delegate?.vimSetSelectedRange(NSRange(location: length - 1, length: 0))
            return
        }

        // Move to end of current word
        let currentIsWord = isWordChar(nsString.character(at: i))
        while i < length - 1 {
            let nextCh = nsString.character(at: i + 1)
            if isWordChar(nextCh) != currentIsWord || nextCh == 0x0A || nextCh == 0x0D {
                break
            }
            i += 1
        }

        delegate?.vimSetSelectedRange(NSRange(location: i, length: 0))
    }

    // MARK: - Find Character on Line (f/F)

    /// Find character on current line (f/F command)
    private func findCharacterOnLine(_ char: Character, forward: Bool) {
        guard let storage = delegate?.vimTextStorage else { return }
        let nsString = storage.string as NSString
        let length = nsString.length
        let cursor = delegate?.vimSelectedRange.location ?? 0
        guard cursor < length else { return }

        // Get current line range
        let lineRange = nsString.lineRange(for: NSRange(location: cursor, length: 0))
        let lineEnd = lineRange.location + lineRange.length

        // Save for ; and , repeats
        lastFChar = char
        lastFWasForward = forward

        let targetChar = char.utf16.first ?? 0

        if forward {
            // Search forward from cursor+1 to end of line
            var i = cursor + 1
            while i < lineEnd {
                let ch = nsString.character(at: i)
                if ch == 0x0A || ch == 0x0D {
                    break
                }
                if ch == targetChar {
                    delegate?.vimSetSelectedRange(NSRange(location: i, length: 0))
                    return
                }
                i += 1
            }
        } else {
            // Search backward from cursor-1 to start of line
            var i = cursor - 1
            while i >= lineRange.location {
                let ch = nsString.character(at: i)
                if ch == targetChar {
                    delegate?.vimSetSelectedRange(NSRange(location: i, length: 0))
                    return
                }
                i -= 1
            }
        }

        // Character not found
        NSSound.beep()
    }

    // MARK: - Search Operations

    /// Search for current word under cursor (* and # commands)
    private func searchCurrentWord(forward: Bool) {
        guard let storage = delegate?.vimTextStorage else { return }
        let nsString = storage.string as NSString
        let length = nsString.length
        let cursor = delegate?.vimSelectedRange.location ?? 0
        guard cursor < length else { return }

        // Find word boundaries around cursor
        func isWordChar(_ c: unichar) -> Bool {
            if let scalar = Unicode.Scalar(c) {
                return CharacterSet.alphanumerics.contains(scalar) || c == 95
            }
            return false
        }

        // Check if cursor is on a word character
        let currentChar = nsString.character(at: cursor)
        guard isWordChar(currentChar) else {
            NSSound.beep()
            return
        }

        // Find start of word
        var wordStart = cursor
        while wordStart > 0 && isWordChar(nsString.character(at: wordStart - 1)) {
            wordStart -= 1
        }

        // Find end of word
        var wordEnd = cursor
        while wordEnd < length - 1 && isWordChar(nsString.character(at: wordEnd + 1)) {
            wordEnd += 1
        }

        let word = nsString.substring(with: NSRange(location: wordStart, length: wordEnd - wordStart + 1))
        searchPattern = word
        searchForward = forward

        // Perform initial search
        findNextSearchResult(forward: forward)
    }

    /// Enter search mode (/ and ? commands)
    private func enterSearchMode(forward: Bool) {
        searchForward = forward
        editorMode = .command
        commandBuffer = forward ? "/" : "?"
        updateStatusBar()
    }

    /// Find next search result (n/N commands)
    private func findNextSearchResult(forward: Bool) {
        guard let storage = delegate?.vimTextStorage, !searchPattern.isEmpty else {
            NSSound.beep()
            return
        }

        let nsString = storage.string as NSString
        let length = nsString.length
        let cursor = delegate?.vimSelectedRange.location ?? 0

        // Determine actual search direction based on original direction and n/N
        let actualForward = searchForward == forward

        if actualForward {
            // Search forward from cursor+1
            let searchStart = min(cursor + 1, length)
            var searchRange = NSRange(location: searchStart, length: length - searchStart)

            var foundRange = nsString.range(of: searchPattern, options: [], range: searchRange)

            // If not found, wrap around to beginning
            if foundRange.location == NSNotFound {
                searchRange = NSRange(location: 0, length: searchStart)
                foundRange = nsString.range(of: searchPattern, options: [], range: searchRange)
            }

            if foundRange.location != NSNotFound {
                delegate?.vimSetSelectedRange(NSRange(location: foundRange.location, length: 0))
                return
            }
        } else {
            // Search backward from cursor-1
            let searchEnd = cursor
            var searchRange = NSRange(location: 0, length: searchEnd)

            var foundRange = nsString.range(of: searchPattern, options: .backwards, range: searchRange)

            // If not found, wrap around to end
            if foundRange.location == NSNotFound {
                searchRange = NSRange(location: searchEnd, length: length - searchEnd)
                foundRange = nsString.range(of: searchPattern, options: .backwards, range: searchRange)
            }

            if foundRange.location != NSNotFound {
                delegate?.vimSetSelectedRange(NSRange(location: foundRange.location, length: 0))
                return
            }
        }

        // Pattern not found
        NSSound.beep()
    }

    // MARK: - Join Lines (J command)

    /// Join current line with next line
    private func joinLines() {
        guard let storage = delegate?.vimTextStorage else { return }
        let nsString = storage.string as NSString
        let length = nsString.length
        let cursor = delegate?.vimSelectedRange.location ?? 0
        guard cursor < length else { return }

        // Get current line range
        let lineRange = nsString.lineRange(for: NSRange(location: cursor, length: 0))
        let lineEnd = lineRange.location + lineRange.length

        // Check if there's a next line
        guard lineEnd < length else {
            NSSound.beep()
            return
        }

        // Find the end of current line content (before newline)
        var contentEnd = lineEnd - 1
        while contentEnd > lineRange.location {
            let ch = nsString.character(at: contentEnd)
            if ch != 0x0A && ch != 0x0D {
                break
            }
            contentEnd -= 1
        }
        contentEnd += 1  // Move back to the newline character

        // Get next line range
        let nextLineRange = nsString.lineRange(for: NSRange(location: lineEnd, length: 0))

        // Find first non-whitespace in next line
        var nextLineStart = nextLineRange.location
        while nextLineStart < nextLineRange.location + nextLineRange.length {
            let ch = nsString.character(at: nextLineStart)
            if ch != 0x20 && ch != 0x09 {
                break
            }
            nextLineStart += 1
        }

        // Calculate the range to delete: from end of current line content to first non-space of next line
        let deleteRange = NSRange(location: contentEnd, length: nextLineStart - contentEnd)

        // Replace with a single space
        if delegate?.vimShouldChangeText(in: deleteRange, replacementString: " ") == true {
            delegate?.vimReplaceCharacters(in: deleteRange, with: " ")
            delegate?.vimDidChangeText()
            delegate?.vimSetSelectedRange(NSRange(location: contentEnd, length: 0))
        }
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
