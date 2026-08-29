import Foundation

struct HistoryEntry: Identifiable, Codable, Hashable {
    enum Source: String, Codable { case local, carplay, applyExport }

    let id: UUID
    let baseName: String
    let createdAt: Date
    let source: Source
    /// Filenames relative to Documents/Exports.
    var darkFileName: String?
    var lightFileName: String?
    var sourceImageName: String?

    init(id: UUID = UUID(),
         baseName: String,
         createdAt: Date = Date(),
         source: Source,
         darkFileName: String? = nil,
         lightFileName: String? = nil,
         sourceImageName: String? = nil) {
        self.id = id
        self.baseName = baseName
        self.createdAt = createdAt
        self.source = source
        self.darkFileName = darkFileName
        self.lightFileName = lightFileName
        self.sourceImageName = sourceImageName
    }
}
