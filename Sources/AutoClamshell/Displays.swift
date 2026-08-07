import CoreGraphics
import Foundation

/// 디스플레이 조회 헬퍼. 메인 스레드 격리 없이 어디서든 쓸 수 있어야 하므로
/// (안전망이 백그라운드 큐에서 호출한다) 순수 함수로 둔다.
enum DisplayInfo {
    static func activeDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    static func externalDisplays() -> [CGDirectDisplayID] {
        activeDisplays().filter { CGDisplayIsBuiltin($0) == 0 }
    }

    /// 내장 디스플레이 ID를 찾는다.
    ///
    /// 논리적으로 꺼진 내장 디스플레이는 `CGGetActiveDisplayList` 는 물론
    /// `CGGetOnlineDisplayList` 에서도 사라지므로 목록 열거로는 찾을 수 없다.
    /// 하지만 ID 자체는 살아 있어 개별 조회에는 응답하므로 ID 공간을 훑는다.
    ///
    /// 유효하지 않은 ID도 `CGDisplayIsBuiltin` 에 true 를 돌려주므로 그것만으로는
    /// 구분되지 않는다. 실제 패널은 vendor 번호와 픽셀 크기가 유효하지만,
    /// 유효하지 않은 ID는 vendor 가 0xFFFFFFFF 이고 크기가 0x0 이다.
    static func findBuiltinDisplay() -> CGDirectDisplayID? {
        for id in scanRange {
            guard CGDisplayIsBuiltin(id) != 0 else { continue }
            let vendor = CGDisplayVendorNumber(id)
            guard vendor != 0, vendor != 0xFFFF_FFFF else { continue }
            guard CGDisplayPixelsWide(id) > 0 else { continue }
            return id
        }
        return nil
    }

    /// 내장일 **가능성이 있는** 모든 ID.
    ///
    /// 재구성 도중에는 내장 패널의 ID 가 바뀌고 vendor/크기가 일시적으로 무효해져서
    /// `findBuiltinDisplay()` 가 nil 을 돌려주는 순간이 있다(실측으로 확인).
    /// 화면이 하나도 없는 긴급 상황에서는 대상을 특정할 여유가 없으므로,
    /// 내장 플래그가 선 ID 를 모두 후보로 삼아 한꺼번에 켠다.
    /// 존재하지 않는 ID 가 섞여도 그 항목만 무시되므로 해가 없다.
    static func builtinCandidates() -> [CGDirectDisplayID] {
        scanRange.filter { CGDisplayIsBuiltin($0) != 0 }
    }

    private static let scanRange = CGDirectDisplayID(1)...CGDirectDisplayID(64)
}
