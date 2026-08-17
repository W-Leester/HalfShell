import AppKit
import Foundation

/// 새 버전을 주기적으로 확인해 메뉴바에 알린다.
///
/// 설정 창을 열었을 때만 확인하면 창을 안 여는 사용자는 영영 모른다. 배경에서
/// 하루 한 번 확인하고, 새 버전이 있으면 메뉴에 항목을 띄운다.
///
/// **다운로드와 설치까지 자동으로 하지는 않는다.** 그러려면 Sparkle 같은
/// 프레임워크가 필요하고, 서명 키 관리와 자동 교체에 따르는 위험이 함께 온다.
/// 이 앱은 잘못 동작하면 화면을 잃는 종류라, 사용자가 언제 바꿀지 정하는 편이 낫다.
@MainActor
final class UpdateMonitor: ObservableObject {
    static let shared = UpdateMonitor()

    /// 새 버전이 있으면 그 버전 문자열. 없으면 nil.
    @Published private(set) var availableVersion: String?

    private static let interval: TimeInterval = 24 * 60 * 60
    private var timer: Timer?

    private init() {}

    func start() {
        // 시작 직후에 바로 때리면 로그인 순간의 네트워크와 겹친다. 잠시 미룬다.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            MainActor.assumeIsolated { self?.checkNow() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkNow() }
        }
        timer?.tolerance = 60 * 60
    }

    func checkNow() {
        Task { [weak self] in
            let result = await UpdateCheck.check()
            await MainActor.run {
                guard let self else { return }
                switch result {
                case .updateAvailable(let version):
                    if self.availableVersion != version {
                        self.availableVersion = version
                        Log.write("[업데이트] 새 버전 \(version) 확인 (현재 \(UpdateCheck.currentVersion))")
                    }
                case .upToDate, .unavailable:
                    if self.availableVersion != nil { self.availableVersion = nil }
                }
            }
        }
    }

    func openReleasesPage() {
        NSWorkspace.shared.open(UpdateCheck.releasesURL)
    }
}
