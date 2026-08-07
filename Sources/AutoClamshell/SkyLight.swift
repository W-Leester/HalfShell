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
/// 옵션 0(forAppOnly)으로 커밋하면 이 프로세스가 종료될 때 변경이 자동으로 되돌아간다 —
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

    /// 프로세스 종료 시 변경이 자동으로 되돌아가는 커밋 옵션.
    private static let optionAppOnly: Int32 = 0

    private let begin: BeginFn
    private let setEnabled: SetEnabledFn
    private let complete: CompleteFn
    private let cancel: CancelFn?

    static let shared: SkyLight? = SkyLight()

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

    func setDisplay(_ displayID: CGDirectDisplayID, enabled: Bool) throws {
        var config: OpaquePointer?
        let beginStatus = begin(&config)
        guard beginStatus == 0, config != nil else { throw Failure.beginFailed(beginStatus) }

        let configureStatus = setEnabled(config, displayID, enabled)
        guard configureStatus == 0 else {
            _ = cancel?(config)
            throw Failure.configureFailed(configureStatus)
        }

        let commitStatus = complete(config, Self.optionAppOnly)
        guard commitStatus == 0 else { throw Failure.commitFailed(commitStatus) }
    }
}
