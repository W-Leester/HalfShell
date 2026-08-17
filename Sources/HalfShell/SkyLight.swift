import CoreGraphics
import Foundation

/// 내장 디스플레이를 활성 배열에서 논리적으로 제거/복구하는 SkyLight 비공개 API 브리지.
///
/// 공개 API(`CGBeginDisplayConfiguration`)와 같은 3단계 트랜잭션 형태이지만,
/// enable/disable 항목은 SkyLight 쪽 함수로만 넣을 수 있다:
///
///   1. `SLSBeginDisplayConfiguration(&config)`
///   2. `SLSConfigureDisplayEnabled(config, displayID, enabled)`
///   3. `SLSCompleteDisplayConfigurationWithOption(config, option)`
///
/// config 객체는 반드시 1번에서 받은 것이어야 하며(공개 API의 config와 다른 타입),
/// 커밋 옵션은 ``CommitScope`` 참고. 옵션 0(appOnly)은 프로세스 종료 시 되돌아간다 —
/// 앱이 죽어도 내장 디스플레이가 꺼진 채 남지 않는 안전장치.
///
/// 심볼은 dlsym으로 런타임에 찾으므로 비공개 프레임워크 링크가 필요 없고,
/// OS 업데이트로 심볼이 사라지면 init이 nil을 반환해 기능이 비활성화될 뿐 크래시하지 않는다.
struct SkyLight {
    enum Failure: LocalizedError {
        case beginFailed(Int32)
        case configureFailed(Int32)
        case commitFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .beginFailed(let code): return "SLSBeginDisplayConfiguration 실패 (코드 \(code))"
            case .configureFailed(let code): return "SLSConfigureDisplayEnabled 실패 (코드 \(code))"
            case .commitFailed(let code): return "구성 커밋 실패 (코드 \(code))"
            }
        }
    }

    private typealias BeginFn = @convention(c) (UnsafeMutablePointer<OpaquePointer?>) -> Int32
    private typealias SetEnabledFn = @convention(c) (OpaquePointer?, CGDirectDisplayID, Bool) -> Int32
    private typealias CompleteFn = @convention(c) (OpaquePointer?, Int32) -> Int32
    private typealias CancelFn = @convention(c) (OpaquePointer?) -> Int32

    /// 커밋 범위.
    ///
    /// 끄기는 `appOnly` 로 커밋한다 — 앱이 죽으면 OS 가 되돌려주길 기대하는 안전장치다.
    /// 다만 실제 패널이 전부 사라진 뒤에는 이 자동 원복이 동작하지 않는 것을 실측으로
    /// 확인했으므로 이것만 믿어서는 안 된다 (``SafetyNet`` 이 진짜 방어선이다).
    ///
    /// 반대로 켜기는 반드시 `session` 이어야 한다. `appOnly` 로 켜면 이 프로세스가
    /// 끝나는 순간 도로 꺼진 상태로 되돌아가기 때문이다.
    enum CommitScope: Int32 {
        case appOnly = 0
        case session = 1
        case permanent = 2
    }

    private let begin: BeginFn
    private let setEnabled: SetEnabledFn
    private let complete: CompleteFn
    private let cancel: CancelFn?

    static let shared: SkyLight? = {
        let instance = SkyLight()
        if instance == nil {
            // macOS 업데이트로 Apple 이 심볼을 치웠다는 뜻이다. 사용자 신고를
            // 기다리면 늦다. 이 신호로 즉시 알 수 있다.
            Telemetry.report("SkyLight 심볼을 찾지 못함 — 기능 사용 불가", extra: [
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
            ])
        }
        return instance
    }()

    private init?() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else {
            return nil
        }
        func resolve<T>(_ names: [String], as type: T.Type) -> T? {
            for name in names {
                if let sym = dlsym(handle, name) {
                    return unsafeBitCast(sym, to: T.self)
                }
            }
            return nil
        }
        // 최신 SLS* 이름을 먼저 찾고, 구버전 CGS* 별칭으로 폴백한다.
        guard
            let begin = resolve(["SLSBeginDisplayConfiguration", "CGSBeginDisplayConfiguration"], as: BeginFn.self),
            let setEnabled = resolve(["SLSConfigureDisplayEnabled", "CGSConfigureDisplayEnabled"], as: SetEnabledFn.self),
            let complete = resolve(
                ["SLSCompleteDisplayConfigurationWithOption", "CGSCompleteDisplayConfigurationWithOption"],
                as: CompleteFn.self)
        else { return nil }

        self.begin = begin
        self.setEnabled = setEnabled
        self.complete = complete
        self.cancel = resolve(["SLSCancelDisplayConfiguration", "CGSCancelDisplayConfiguration"], as: CancelFn.self)
    }

    func setDisplay(_ displayID: CGDirectDisplayID, enabled: Bool, scope: CommitScope) throws {
        var config: OpaquePointer?
        let beginStatus = begin(&config)
        guard beginStatus == 0, config != nil else { throw Failure.beginFailed(beginStatus) }

        let configureStatus = setEnabled(config, displayID, enabled)
        guard configureStatus == 0 else {
            _ = cancel?(config)
            throw Failure.configureFailed(configureStatus)
        }

        // 커밋이 얼마나 걸렸는지 재둔다. 실패하는 커밋이 약 10초를 잡는 것을
        // 실측했고, 그것이 반복되면 배터리를 태운다.
        let startedAt = Date()
        let commitStatus = complete(config, scope.rawValue)
        Telemetry.noteSlowCommit(enabled ? "enable" : "disable",
                                 seconds: Date().timeIntervalSince(startedAt))
        guard commitStatus == 0 else { throw Failure.commitFailed(commitStatus) }
    }
}
