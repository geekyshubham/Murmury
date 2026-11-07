import Foundation
import MurmuryKit

MainActor.assumeIsolated {
    do {
        if let code = try Launcher.runToolIfRequested(from: CommandLine.arguments) { exit(code) }
        if try !Launcher.renderIconIfRequested(from: CommandLine.arguments) { Launcher.run() }
    } catch {
        FileHandle.standardError.write(Data("Murmury tool failed: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}
