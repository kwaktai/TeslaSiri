import Foundation

/// Writes raw vehicle API diagnostic exports to disk and summarizes response outcomes.
nonisolated enum FleetRawDataExporter {
    struct Summary: Sendable {
        let message: String
        let latestRequestID: String?
    }

    @concurrent
    static func write(_ export: FleetRawDataExport) async throws -> URL {
        try Task.checkCancellation()
        let directoryURL = try exportDirectoryURL()
        let fileURL = directoryURL.appendingPathComponent(
            fileName(vin: export.vin, generatedAt: export.generatedAt)
        )

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        let data = try encoder.encode(export)
        try Task.checkCancellation()
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        return fileURL
    }

    @concurrent
    static func discard(_ url: URL) async {
        try? FileManager.default.removeItem(at: url)
    }

    static func summary(for export: FleetRawDataExport) -> Summary {
        let successfulCount = export.responses.filter { response in
            guard let statusCode = response.statusCode else {
                return false
            }
            return (200..<300).contains(statusCode)
        }.count
        let totalCount = export.responses.count
        let failedCount = totalCount - successfulCount

        let message = failedCount == 0
            ? "Exported \(totalCount) raw responses."
            : "Exported \(successfulCount)/\(totalCount) raw responses."
        let latestRequestID = export.responses.reversed().first { $0.requestID != nil }?.requestID

        return Summary(message: message, latestRequestID: latestRequestID)
    }

    private static func exportDirectoryURL() throws -> URL {
        let fileManager = FileManager.default
        let documentsURL = try fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directoryURL = documentsURL.appendingPathComponent("Fleet Raw Exports", isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        var excludedDirectoryURL = directoryURL
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? excludedDirectoryURL.setResourceValues(resourceValues)

        return directoryURL
    }

    private static func fileName(vin: String, generatedAt: Int64) -> String {
        let safeVINSuffix = vin.suffix(6).filter { $0.isLetter || $0.isNumber }
        let suffix = safeVINSuffix.isEmpty ? "vehicle" : String(safeVINSuffix)
        return "fleet-raw-\(suffix)-\(generatedAt / 1_000)-\(UUID().uuidString).json"
    }
}
