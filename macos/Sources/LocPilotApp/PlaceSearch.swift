import MapKit

/// 一条搜索候选。`id` 由坐标 + 名称拼成，保证 ForEach 不会复用错行。
struct SearchItem: Identifiable, Equatable {
    let title: String
    let subtitle: String?
    let lat: Double
    let lon: Double

    var id: String { "\(lat),\(lon),\(title)" }
}

/// 地点搜索：走**系统地图**（`MKLocalSearch`），不用后端的地理编码。
///
/// 为什么换掉原来的 Nominatim：
/// Nominatim 的数据来自 OpenStreetMap，OSM 在中国的 POI 覆盖非常稀疏 ——
/// "广州塔""万象城""深圳湾公园"这类日常地点大量搜不到，用户体验是"根本搜不动"。
/// 而 Apple 地图在中国大陆用的是高德数据，POI 密度和地图上看到的完全一致，
/// 且不需要任何 API key、不需要额外账号。
///
/// 保留后端 `/api/search` 作兜底：极少数 Apple 也搜不到的地点（比如某个小店），
/// OSM 偶尔能命中，总比空列表强。
enum LocalPlaceSearch {
    /// 在指定区域内搜。`region` 传当前可见范围：结果会优先这一片，
    /// 否则搜"万象城"会给出全国各地的同名地点。
    static func search(_ query: String, in region: MKCoordinateRegion) async -> [SearchItem] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = region
        request.resultTypes = [.pointOfInterest, .address]

        do {
            let response = try await MKLocalSearch(request: request).start()
            return response.mapItems.compactMap { item in
                guard let name = item.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
                let coordinate = item.placemark.coordinate
                // 坐标非法（0,0）的直接丢掉，否则会跳到大西洋
                guard CLLocationCoordinate2DIsValid(coordinate),
                      !(abs(coordinate.latitude) < 0.01 && abs(coordinate.longitude) < 0.01) else { return nil }
                let address = item.placemark.title?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return SearchItem(
                    title: name,
                    subtitle: cleaned(address, removing: name),
                    lat: coordinate.latitude,
                    lon: coordinate.longitude
                )
            }
        } catch {
            return []
        }
    }

    /// Apple 返回的地址形如「广州塔, 阅江西路 222 号, 海珠区, 广州市」，
    /// 首段往往就是名称本身，去掉免得列表里同一个词出现两遍。
    private static func cleaned(_ address: String, removing name: String) -> String? {
        var text = address
        if text.hasPrefix(name) {
            text = String(text.dropFirst(name.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: ",，、 "))
        }
        return text.isEmpty ? nil : text
    }
}
