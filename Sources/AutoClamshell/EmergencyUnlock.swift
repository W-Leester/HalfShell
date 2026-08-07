import AppKit
import ApplicationServices
import Foundation

/// 비상 탈출 — Command 키를 빠르게 연타하면 내장 디스플레이를 되살린다.
///
/// 자동 복구가 어떤 이유로든 실패했을 때, **화면이 보이지 않는 상태에서** 손만으로
/// 빠져나올 마지막 수단이다. 조합키를 외울 필요 없이 당황해서 두드려도 걸리도록
/// Command 단독 연타로 잡는다.
///
/// 오발 방지가 관건이다. Command 는 평소 늘 다른 키와 함께 쓰이므로,
/// **사이에 다른 키가 하나라도 눌리면 카운트를 버린다.** 다른 보조키가 섞여도
/// 마찬가지다. 그래서 Cmd+C, Cmd+Tab 같은 일상적인 단축키로는 걸리지 않는다.
/// 순수하게 Command 만 \(requiredTaps)번, \(window)초 안에 눌러야 발동한다.
///
/// 전역 키 모니터라 손쉬운 사용(입력 모니터링) 권한이 필요하다. 권한이 없으면
/// 조용히 비활성 상태로 남고, 나머지 기능에는 영향을 주지 않는다.
@MainActor
final class EmergencyUnlock {
    static let requiredTaps = 5
    static let window: TimeInterval = 2

    private var monitors: [Any] = []
    private var tapTimes: [Date] = []
    private var commandWasDown = false
    private let onTrigger: () -> Void

    init(onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
    }

    var isTrusted: Bool { AXIsProcessTrusted() }
    var isRunning: Bool { !monitors.isEmpty }

    /// 권한 대화상자를 띄운다. 이미 허용돼 있으면 아무 일도 일어나지 않는다.
    func requestPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func start() {
        stop()
        guard isTrusted else {
            Log.write("[비상] 손쉬운 사용 권한이 없어 연타 감지를 시작하지 못함")
            return
        }
        let flagMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.handleFlagsChanged(event) }
        }
        // 다른 키가 눌리면 "단독 연타"가 아니므로 처음부터 다시 센다.
        let keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.resetCount() }
        }
        monitors = [flagMonitor, keyMonitor].compactMap { $0 }
        Log.write("[비상] Command \(Self.requiredTaps)번 연타 감지 시작")
    }

    func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        resetCount()
    }

    // MARK: - Private

    private func handleFlagsChanged(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let otherModifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .function, .capsLock]
        guard flags.intersection(otherModifiers).isEmpty else {
            resetCount()
            return
        }

        let commandDown = flags.contains(.command)
        defer { commandWasDown = commandDown }
        guard commandDown, !commandWasDown else { return }  // 누르는 순간만 센다(뗄 때는 무시)

        let now = Date()
        tapTimes.append(now)
        tapTimes.removeAll { now.timeIntervalSince($0) > Self.window }

        guard tapTimes.count >= Self.requiredTaps else { return }
        resetCount()
        Log.write("[비상] Command 연타 감지 → 내장 디스플레이 복구")
        onTrigger()
    }

    private func resetCount() {
        tapTimes.removeAll()
    }
}
