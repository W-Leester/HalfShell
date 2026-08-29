import Foundation
import IOKit
import IOKit.ps

/// 디스플레이가 **물리적으로** 연결되어 있다는 독립 증거를 읽는다.
///
/// WindowServer 의 화면 목록은 깨어날 때 기억(저장된 배치)으로 채워질 수 있어서,
/// 실제로는 뽑힌 모니터가 목록에 남는다(유령 — 사건 3). 유령은 진짜의 신원을
/// 그대로 물려받으므로 **목록 안에서는 구분이 불가능하다는 것까지 실측됐다.**
///
/// 그러나 유령은 macOS 의 기억이 만든 존재라 기억 밖의 것은 만들지 못한다 —
/// 실제 케이블. 디스플레이 코프로세서(DCP)는 전기적으로 살아 있는 링크마다
/// `DCPAVServiceProxy` 노드(Location=External)를 만들고, 케이블이 없으면
/// 이 노드가 생길 수 없다(고 가설한다).
///
/// **현재는 진단 전용이다.** "유령은 이 장부에 없다"는 아직 가설이므로, 판단에
/// 쓰지 않고 화면 목록과 나란히 기록만 한다. 유령이 자연 발생하는 순간의 로그가
/// 가설을 확정하거나 기각한다. 확정되면 재무장 조건("물리 링크 수 ≥ 목록의
/// 외장 수 → 진짜 → 즉시 자동 끄기 재개")으로 승격할 수 있다 — 그 경우에도
/// 증거가 있을 때만 끄고 없으면 지금처럼 보류하므로, 최악의 경우가 현재 동작이다.
enum PhysicalLink {
    /// 물리적 외장 링크 수. DCP 가 없는 환경(Intel 등)이면 nil.
    ///
    /// nil 과 0 의 구분이 중요하다: 0 은 "단자에 아무것도 없다"는 증언이고,
    /// nil 은 "이 장부 자체가 없어서 증언할 수 없다"이다. Intel Mac 에서
    /// 0 으로 잘못 답하면 진짜 외장을 유령으로 모는 셈이 된다.
    static func externalCount() -> Int? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var total = 0
        var external = 0
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            total += 1
            let location = IORegistryEntryCreateCFProperty(
                service, "Location" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? String
            if location == "External" { external += 1 }
        }
        // 노드가 하나도 없으면 이 Mac 은 DCP 장부를 쓰지 않는 것이다(미지원).
        return total == 0 ? nil : external
    }

    /// AC 전원(독·어댑터) 연결 여부. 독은 전원을 함께 공급하므로 보조 증거가 된다.
    /// 8/23 사건에서 화면 목록은 속았지만 전원 관리자는 진실을 알고 있었다.
    static var onACPower: Bool {
        IOPSCopyExternalPowerAdapterDetails() != nil
    }

    /// 로그용 한 줄 요약.
    static func describe() -> String {
        let link = externalCount().map(String.init) ?? "미지원"
        return "물리링크=\(link) 전원=\(onACPower ? "AC" : "배터리")"
    }
}
