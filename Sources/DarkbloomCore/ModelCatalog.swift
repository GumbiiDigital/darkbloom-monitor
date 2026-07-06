import Foundation

public enum ModelCatalog {
    public static let preferredGemma26BID = "gemma-4-26b-qat-4bit"

    private static let legacyGemma26BIDs: Set<String> = [
        "gemma-4-26b",
        "gemma-4-26b-8bit"
    ]

    public static func pickerModels(_ models: [CoordinatorAPI.CatalogModel]) -> [CoordinatorAPI.CatalogModel] {
        let ids = Set(models.map(\.id))
        let hasPreferredGemma = ids.contains(preferredGemma26BID)

        return models.compactMap { model in
            if hasPreferredGemma && legacyGemma26BIDs.contains(model.id) {
                return nil
            }
            if model.id == preferredGemma26BID {
                var preferred = model
                preferred.displayName = "Gemma 4 26B 4-bit"
                return preferred
            }
            return model
        }
    }

    public static func canonicalModelID(_ id: String, availableIDs: Set<String>) -> String {
        if availableIDs.contains(preferredGemma26BID),
           legacyGemma26BIDs.contains(id) {
            return preferredGemma26BID
        }
        return id
    }

    public static func canonicalModelIDs(_ ids: [String], availableIDs: Set<String>) -> Set<String> {
        Set(ids.map { canonicalModelID($0, availableIDs: availableIDs) })
    }
}
