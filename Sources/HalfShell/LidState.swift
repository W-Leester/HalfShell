import Foundation
import IOKit

/// 맥북 뚜껑이 닫혀 있는지 읽는다.
///
/// 상태 기계에 이 개념이 없어서 사건 5가 났다. 내장 디스플레이가 꺼지는 이유를
/// "우리가 껐다 / 외장이 붙었다 / 남이 껐다" 세 가지로만 나눠 뒀는데 네 번째가
/// 있었다 — **사용자가 뚜껑을 닫았다.** 규칙 2가 그것을 "남이 껐다"로 오인해서,
/// 클램쉘로 들어가려는 것을 매번 되돌렸다.
///
/// 값은 `IOPMrootDomain` 의 `AppleClamshellState` 다. 비공개 API 가 아니라
/// IORegistry 에 공개된 속성이라 `ioreg -r -k AppleClamshellState` 로도 볼 수 있다.
///
/// **읽지 못하면 "열림"으로 답한다.** 이 값은 내장을 켤지 말지를 정하는 데 쓰이므로
/// 틀리는 방향이 중요하다. "닫힘"으로 잘못 답하면 복구가 막혀 사용자가 검은 화면에
/// 갇힌다. "열림"으로 잘못 답하면 이번 버그가 재발할 뿐이다. 후자가 훨씬 가볍다.
///
/// 뚜껑이 없는 Mac(mini·Studio·Pro)에는 이 키가 아예 없어서 자연히 "열림"이 된다.
enum LidState {
    static var isClosed: Bool {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }

        guard let raw = IORegistryEntryCreateCFProperty(
            service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() else { return false }

        // 확실히 불리언으로 읽힐 때만 "닫힘"이라고 답한다.
        guard let closed = raw as? Bool else { return false }
        return closed
    }
}
