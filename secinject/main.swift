//
//  main.swift
//  secinject - Secrets injector thing
//
//  Created by Andy Frey on 12/29/25.
//

import Foundation

// Configuration Defaults
var envFilePath = "~/.env"
var outputFileName = "Secrets.swift"
var gitignorePath = ".gitignore"
var includeKeys: Set<String>? = nil // If nil, include all keys. If set, include only these.

// Helper function to handle tilde expansion (e.g., ~/.env -> /Users/andy/.env)
func expandPath(_ path: String) -> String {
    return (path as NSString).expandingTildeInPath
}

// Parse Command Line Arguments
// We skip the first argument which is the executable path
var arguments = Array(CommandLine.arguments.dropFirst())

while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    
    switch argument {
    case "--secrets-file":
        guard !arguments.isEmpty else {
            fputs("Error: Missing value for --secrets-file\n", stderr)
            exit(1)
        }
        envFilePath = arguments.removeFirst()
        
    case "--output-file":
        guard !arguments.isEmpty else {
            fputs("Error: Missing value for --output-file\n", stderr)
            exit(1)
        }
        outputFileName = arguments.removeFirst()
        
    case "--gitignore-file":
        guard !arguments.isEmpty else {
            fputs("Error: Missing value for --gitignore-file\n", stderr)
            exit(1)
        }
        gitignorePath = arguments.removeFirst()
        
    case "--include-keys":
        guard !arguments.isEmpty else {
            fputs("Error: Missing value for --include-keys\n", stderr)
            exit(1)
        }
        let keysString = arguments.removeFirst()
        let keysArray = keysString.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        includeKeys = Set(keysArray)
        
    case "-h", "--help":
        let executableName = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
        print("Usage: \(executableName) [options]")
        print("\nOptions:")
        print("  --secrets-file <path>   Path to environment file (default: ~/.env)")
        print("  --output-file <path>    Path to generated Swift file (default: Secrets.swift)")
        print("  --gitignore-file <path> Path to .gitignore file (default: .gitignore)")
        print("  --include-keys <list>   Comma-separated list of keys to include (default: all)")
        exit(0)
        
    default:
        fputs("Error: Unknown argument '\(argument)'\n", stderr)
        exit(1)
    }
}

// Expand paths to ensure ~ works even if the default string is used
let resolvedEnvPath = expandPath(envFilePath)
let resolvedOutputPath = expandPath(outputFileName)
let resolvedGitignorePath = expandPath(gitignorePath)

// Step 2: Verify Files Exist & Ensure Safety
let fileManager = FileManager.default
var hasErrors = false

// 1. Verify Input File
if !fileManager.fileExists(atPath: resolvedEnvPath) {
    fputs("Error: Input environment file does not exist at path: \(resolvedEnvPath)\n", stderr)
    hasErrors = true
}

// If inputs are missing, we stop here before touching .gitignore or other side effects
if hasErrors {
    exit(1)
}

// 2. Ensure .gitignore Exists and Includes Output File
do {
    // We need the filename of the output file relative to the gitignore location
    // However, gitignore patterns are usually relative to the gitignore file itself.
    // Calculating the relative path is complex, so for safety we will add the *filename*
    // of the output file. If the user puts Secrets.swift in a subdir, they might need to manage
    // the gitignore manually if they want precise path matching, but adding the filename is
    // a safe default that usually works or at least provides a warning.
    let outputURL = URL(fileURLWithPath: resolvedOutputPath)
    let outputFilenameOnly = outputURL.lastPathComponent

    if fileManager.fileExists(atPath: resolvedGitignorePath) {
        // Read existing .gitignore
        let content = try String(contentsOfFile: resolvedGitignorePath, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        
        // Check if output filename is already ignored
        if !lines.contains(outputFilenameOnly) {
            // Append to .gitignore
            let prefix = content.hasSuffix("\n") ? "" : "\n"
            let newContent = content + prefix + outputFilenameOnly + "\n"
            try newContent.write(toFile: resolvedGitignorePath, atomically: true, encoding: .utf8)
            print("Safety Update:        Added '\(outputFilenameOnly)' to \(resolvedGitignorePath)")
        } else {
            print("Safety Check:         '\(outputFilenameOnly)' is already ignored in \(resolvedGitignorePath)")
        }
    } else {
        // Create new .gitignore
        let content = outputFilenameOnly + "\n"
        try content.write(toFile: resolvedGitignorePath, atomically: true, encoding: .utf8)
        print("Safety Update:        Created \(resolvedGitignorePath) with '\(outputFilenameOnly)'")
    }
} catch {
    fputs("Error: Failed to process .gitignore at \(resolvedGitignorePath): \(error)\n", stderr)
    exit(1)
}

// Step 3: Parse Environment File
print("--- Parsing Secrets ---")
var secrets: [(key: String, value: String)] = []

do {
    let content = try String(contentsOfFile: resolvedEnvPath, encoding: .utf8)
    let lines = content.components(separatedBy: .newlines)
    
    for (index, line) in lines.enumerated() {
        var trimmedLine = line.trimmingCharacters(in: .whitespaces)
        
        // Skip empty lines and comments
        if trimmedLine.isEmpty || trimmedLine.hasPrefix("#") {
            continue
        }
        
        // Handle lines starting with "export "
        if trimmedLine.hasPrefix("export ") {
            trimmedLine = String(trimmedLine.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }
        
        // Check for valid key=value format
        // We look for the first equals sign
        if let range = trimmedLine.range(of: "=") {
            let key = String(trimmedLine[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmedLine[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            
            // Validate key (simple check: not empty, no spaces)
            if key.isEmpty {
                fputs("Error: Empty key on line \(index + 1)\n", stderr)
                hasErrors = true
                continue
            }
            
            if key.contains(" ") {
                fputs("Error: Key contains spaces on line \(index + 1): '\(key)'\n", stderr)
                hasErrors = true
                continue
            }
            
            // Filter keys if a whitelist is provided
            if let allowedKeys = includeKeys {
                if !allowedKeys.contains(key) {
                    continue
                }
            }
            
            secrets.append((key, value))
        } else {
            fputs("Error: Invalid format on line \(index + 1). Expected 'key=value' or 'export key=value'.\n", stderr)
            hasErrors = true
        }
    }
} catch {
    fputs("Error: Failed to read environment file: \(error)\n", stderr)
    exit(1)
}
if hasErrors {
    fputs("Aborting due to validation errors.\n", stderr)
    exit(1)
}

// Step 4: Generate Swift File
print("--- Generating Swift File ---")

// Construct the Swift file content
var swiftContent = """
//
//  \(URL(fileURLWithPath: resolvedOutputPath).lastPathComponent)
//  Generated by Inject-O-Secret
//
//  DO NOT MODIFY THIS FILE DIRECTLY. (It's auto-generated.)
//

import Foundation

enum Secrets {

"""

for secret in secrets {
    // Escape special characters in the value for Swift string literal
    let escapedValue = secret.value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
    
    swiftContent += "    static let \(secret.key) = \"\(escapedValue)\"\n"
}

swiftContent += "}\n"

// Write to file
do {
    try swiftContent.write(toFile: resolvedOutputPath, atomically: true, encoding: .utf8)
    print("Success: Generated \(resolvedOutputPath) with \(secrets.count) secrets.")
} catch {
    fputs("Error: Failed to write output file: \(error)\n", stderr)
    exit(1)
}

