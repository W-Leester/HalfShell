import CoreGraphics
import Foundation

/// 디스플레이 조회 헬퍼. 메인 스레드 격리 없이 어디서든 쓸 수 있어야 하므로
/// (안전망이 백그라운드 큐에서 호출한다) 순수 함수로 둔다.
enum DisplayInfo {
    /// 실제 패널이 하나도 없을 때 macOS 가 만들어내는 자리표시자 디스플레이의 표식.
    ///
    /// vendor/model 번호가 숫자가 아니라 ASCII 4글자다 — `"unkn"` / `"virt"`.
    /// 이 가상 디스플레이는 `CGDisplayIsBuiltin` 이 false 라서 그냥 두면 외장으로
    /// 오인되고, 그러면 "외장이 있으니 괜찮다"고 판단해 복구를 하지 않게 된다.
    /// 실측한 값: vendor=1970170734("unkn"), model=1986622068("virt"), 1920x1080.
    private static let virtualVendor: UInt32 = 0x756E_6B6E  // "unkn"
    private static let virtualModel: UInt32 = 0x7669_7274  // "virt"

    static func isVirtual(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayVendorNumber(id) == virtualVendor || CGDisplayModelNumber(id) == virtualModel
    }

    static func activeDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    /// 가상 자리표시자를 뺀, 실제로 화면이 나오는 디스플레이만.
    static func realActiveDisplays() -> [CGDirectDisplayID] {
        activeDisplays().filter { !isVirtual($0) }
    }

    static func externalDisplays() -> [CGDirectDisplayID] {
        realActiveDisplays().filter { CGDisplayIsBuiltin($0) == 0 }
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

    private static let scanRange = CGDirectDisplayID(1)...CGDirectDisplayID(64)
}

/// 내장 디스플레이 ID 를 기억한다.
///
/// 내장을 끄면 ID 공간에서 완전히 사라져 조회로는 다시 찾을 수 없다. 앱이 재시작되면
/// 메모리 캐시마저 잃는다. 그러면 복구할 대상을 영영 모르게 되므로 디스크에 남긴다.
/// 살아 있을 때 본 값을 계속 갱신해 두고, 사라진 뒤에는 그 값으로 되살린다.
enum BuiltinDisplay {
    private static let key = "lastKnownBuiltinDisplayID"

    /// 지금 조회되면 그 값을(기록도 갱신), 안 되면 마지막으로 기록된 값을 돌려준다.
    static func resolve() -> CGDirectDisplayID? {
        if let live = DisplayInfo.findBuiltinDisplay() {
            UserDefaults.standard.set(Int(live), forKey: key)
            return live
        }
        return lastKnownID
    }

    static var lastKnownID: CGDirectDisplayID? {
        let stored = UserDefaults.standard.integer(forKey: key)
        return stored > 0 ? CGDirectDisplayID(stored) : nil
    }
}
