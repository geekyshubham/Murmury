import Foundation

/// Where the user's takes and trained model live. Default: ~/Library/Application Support/Murmury.
/// Tests pass their own directory so they never touch real data.
struct DatasetStore: Sendable {
    let directory: URL

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    static let standard = DatasetStore(directory: FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Murmury", isDirectory: true))

    var datasetURL: URL { directory.appendingPathComponent("dataset.json") }
    var modelURL: URL { directory.appendingPathComponent("MotionClassifier.mlmodel") }
    var modelMetaURL: URL { directory.appendingPathComponent("MotionClassifier.json") }

    func load() -> [Take] {
        guard let data = try? Data(contentsOf: datasetURL) else { return [] }
        return (try? JSONDecoder().decode([Take].self, from: data)) ?? []
    }

    func save(_ takes: [Take]) {
        guard let data = try? JSONEncoder().encode(takes) else { return }
        try? data.write(to: datasetURL, options: .atomic)
    }
}
