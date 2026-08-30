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
/// `DCPAVServiceProxy` 노드(Location=External)를 만든다.
///
/// 8/30 05:00:01 에 가설을 지지하는 첫 실측이 나왔다. 독을 뽑은 직후 0.7초 동안
/// 화면 목록은 진짜 신원(v=16652 m=49934)을 가진 외장을 계속 들고 있었고 기존
/// 가짜 판별기도 그것을 "실제"로 분류했는데, **물리 링크는 이미 0이었다.**
/// 판별기가 못 거르는 것을 이 장부가 걸렀다.
///
/// **아직 진단 전용이다.** 사건 3의 유령은 "깨어날 때 오래 머무는" 부류인데
/// 그 순간에도 통하는지는 미확인이다. 판단에 쓰지 않고 기록만 한다.
enum PhysicalLink {
    /// 장부 조회 결과. **세 상태를 구분하는 것이 핵심이다.**
    ///
    /// 처음에는 "노드 0개 = 이 Mac 은 DCP 를 안 쓴다(Intel 등)"로 단정했다가
    /// 8/30 에 틀렸음이 드러났다 — 잠자기·깨어남 중에는 노드가 통째로 사라졌다가
    /// 1초쯤 뒤 돌아온다(16:54:26 미지원 → 16:54:27 1). 하필 판정이 가장 필요한
    /// 깨어나는 순간이 이 구간이라, 구분하지 않으면 실험 데이터가 매번 비어 버린다.
    enum Reading {
        /// 확정된 외장 링크 수.
        case count(Int)
        /// 장부는 존재하는데 지금 비어 있다 — 잠자기·전환 중. 곧 돌아온다.
        case notReady
        /// 이 Mac 에는 장부 자체가 없다(Intel 등). 영영 판정할 수 없다.
        case unsupported

        var text: String {
            switch self {
            case .count(let n): return String(n)
            case .notReady: return "준비중"
            case .unsupported: return "미지원"
            }
        }
    }

    /// 이 기기에서 DCP 노드를 **한 번이라도** 본 적이 있는가.
    ///
    /// 이 걸쇠가 `준비중`과 `미지원`을 가른다. 한 번 본 기기라면 이후의 0개는
    /// 전환 중이라는 뜻이고, 한 번도 못 본 기기는 정말 없는 것이다.
    /// 앱을 잠자기 중에 처음 켠 경우를 대비해 실행 간에도 기억한다.
    private static let seenKey = "physicalLinkSeenDCP"
    private static var hasEverSeenNodes: Bool {
        get { UserDefaults.standard.bool(forKey: seenKey) }
        set { UserDefaults.standard.set(newValue, forKey: seenKey) }
    }

    static func read() -> Reading {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator
        ) == KERN_SUCCESS else {
            return hasEverSeenNodes ? .notReady : .unsupported
        }
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

        guard total > 0 else {
            return hasEverSeenNodes ? .notReady : .unsupported
        }
        if !hasEverSeenNodes { hasEverSeenNodes = true }
        return .count(external)
    }

    /// AC 전원(독·어댑터) 연결 여부. 독은 전원을 함께 공급하므로 보조 증거가 된다.
    /// 8/23 사건에서 화면 목록은 속았지만 전원 관리자는 진실을 알고 있었다.
    static var onACPower: Bool {
        IOPSCopyExternalPowerAdapterDetails() != nil
    }

    /// 로그용 한 줄 요약.
    static func describe() -> String {
        "물리링크=\(read().text) 전원=\(onACPower ? "AC" : "배터리")"
    }

    /// 장부가 준비될 때까지 기다렸다가 결과를 넘긴다.
    ///
    /// 깨어나는 순간은 DCP 가 아직 안 올라온 구간이라 즉시 조회하면 `준비중`만
    /// 나온다. 정작 필요한 시점의 데이터가 비는 것을 막으려고 몇 초 재시도한다.
    /// **관측 전용이므로 실패해도 아무 동작에 영향이 없다.**
    static func readWhenReady(attemptsLeft: Int = 12,
                              interval: TimeInterval = 0.5,
                              completion: @escaping (Reading) -> Void) {
        let reading = read()
        switch reading {
        case .count, .unsupported:
            completion(reading)
        case .notReady:
            guard attemptsLeft > 1 else { completion(reading); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + interval) {
                readWhenReady(attemptsLeft: attemptsLeft - 1,
                              interval: interval, completion: completion)
            }
        }
    }
}
