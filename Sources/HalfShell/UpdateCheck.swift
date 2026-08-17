import Foundation

/// 새 버전 확인.
///
/// App Store 를 거치지 않는 앱은 스스로 업데이트를 알려야 한다. GitHub Releases 의
/// 최신 태그를 읽어 현재 버전과 비교하는 것이 가장 가벼운 방법이다 — 서버도,
/// 프레임워크 의존성도 필요 없다.
///
/// 자동 설치까지 하려면 Sparkle 같은 프레임워크가 필요하지만, 그 전에 "새 버전이
/// 나왔다"를 알리는 것만으로도 대부분의 목적은 달성된다.
enum UpdateCheck {
    /// 저장소가 비공개인 동안에는 조회가 실패한다. 그때는 조용히 "확인 불가"로 둔다.
    static let releasesURL = URL(string: "https://github.com/W-Leester/HalfShell/releases/latest")!
    private static let apiURL = URL(string: "https://api.github.com/repos/W-Leester/HalfShell/releases/latest")!

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    static var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    enum Result {
        case upToDate
        case updateAvailable(String)
        case unavailable
    }

    static func check() async -> Result {
        var request = URLRequest(url: apiURL)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String
        else { return .unavailable }

        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return isNewer(latest, than: currentVersion) ? .updateAvailable(latest) : .upToDate
    }

    /// "1.2.10" 이 "1.2.9" 보다 높다는 것을 알아야 하므로 문자열 비교로는 안 된다.
    /// 마디를 숫자로 끊어 비교한다.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
