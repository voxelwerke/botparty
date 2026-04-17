//
//  AnsiParser.swift
//  Botparty
//
//  Created by Ben Nolan on 18/04/2026.
//


import SwiftUI
import Foundation

func finalizeShellBytes(_ input: String) -> Data {
    // 1. Unescape literal octal strings (e.g., "\033" -> actual ESC byte)
    // We use a regex to find \ followed by 3 octal digits
    let octalPattern = #"\\([0-7]{3})"#
    var processedString = input
    
    if let regex = try? NSRegularExpression(pattern: octalPattern) {
        let matches = regex.matches(in: input, range: NSRange(input.startIndex..., in: input)).reversed()
        for match in matches {
            if let octalRange = Range(match.range(at: 1), in: processedString),
               let byte = UInt8(processedString[octalRange], radix: 8) {
                let char = String(UnicodeScalar(byte))
                let fullMatchRange = Range(match.range(at: 0), in: processedString)!
                processedString.replaceSubrange(fullMatchRange, with: char)
            }
        }
    }

    // 2. Remove ANSI sequences (ESC[...m)
    // Now that \033 is an actual ESC byte (\u{1B}), we can target it
    let ansiPattern = #"\x1b\[[0-9;]*[a-zA-Z]"#
    processedString = processedString.replacingOccurrences(of: ansiPattern, with: "", options: .regularExpression)

    // 3. Strip Emojis/Non-ASCII characters that trip up simple shells
    // This keeps only printable ASCII (32-126) and newlines/tabs
    let cleanCode = processedString.unicodeScalars.filter {
        ($0.value >= 32 && $0.value <= 126) || $0.value == 10 || $0.value == 9
    }.map { String($0) }.joined()

    // 4. Return as Data for the VM
    return cleanCode.data(using: .utf8) ?? Data()
}



import SwiftUI

class AnsiParser {
    static func parse(_ input: String) -> AttributedString {
        var result = AttributedString()
        var container = AttributeContainer()
        container.font = .system(.body, design: .monospaced)
        
        // 1. Normalize literal escapes and literal newlines into actual control chars
        var text = input
            .replacingOccurrences(of: "\\033[", with: "\u{1b}[")
            .replacingOccurrences(of: "\\e[", with: "\u{1b}[")
            .replacingOccurrences(of: "\\n", with: "\n") // Fixes the newline issue globally
            .replacingOccurrences(of: "\\r", with: "\r")

        // 2. Use a Regex to find the escape sequences
        // Matches ESC[ followed by numbers/semicolons and ending in a letter (usually 'm')
        let pattern = #"\u{1b}\[([0-9;]*)([a-zA-Z])"#
        
        var currentIndex = text.startIndex
        
        while let range = text.range(of: pattern, options: .regularExpression, range: currentIndex..<text.endIndex) {
            // Add the text BEFORE the escape sequence
            let plainText = String(text[currentIndex..<range.lowerBound])
            var segment = AttributedString(plainText)
            segment.mergeAttributes(container)
            result += segment
            
            // Extract the code (e.g., "1;31") and the command (e.g., "m")
            let match = text[range]
            if match.hasSuffix("m") {
                let codes = match
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\u{1b}[m"))
                    .components(separatedBy: ";")
                
                for code in codes {
                    updateAttributes(&container, for: code)
                }
            }
            
            currentIndex = range.upperBound
        }
        
        // Add any remaining text after the last escape code
        let remaining = String(text[currentIndex...])
        var finalSegment = AttributedString(remaining)
        finalSegment.mergeAttributes(container)
        result += finalSegment
        
        return result
    }
    
    private static func updateAttributes(_ container: inout AttributeContainer, for code: String) {
        let cleanCode = code.trimmingCharacters(in: .whitespaces)
        switch cleanCode {
        case "0":
            container = AttributeContainer()
            container.font = .system(.body, design: .monospaced)
        case "1":
            container.font = .system(.body, design: .monospaced).bold()
        case "31": container.foregroundColor = .red
        case "32": container.foregroundColor = .green
        case "33": container.foregroundColor = .yellow
        case "34": container.foregroundColor = .blue
        case "35": container.foregroundColor = .magenta
        case "36": container.foregroundColor = .cyan
        default: break
        }
    }
}
