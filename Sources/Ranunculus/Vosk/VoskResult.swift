import Foundation

struct VoskPartialResult: Decodable {
    let partial: String
}

struct VoskFinalResult: Decodable {
    let text: String
}

enum VoskResultParser {
    private static let decoder = JSONDecoder()

    /// 部分結果 JSON ("{"partial": "..."}") からテキストを抽出する。
    static func parsePartial(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let result = try? decoder.decode(VoskPartialResult.self, from: data) else {
            return nil
        }
        return result.partial
    }

    /// 確定結果 JSON ("{"text": "..."}") からテキストを抽出する。
    static func parseFinal(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let result = try? decoder.decode(VoskFinalResult.self, from: data) else {
            return nil
        }
        return result.text
    }
}
