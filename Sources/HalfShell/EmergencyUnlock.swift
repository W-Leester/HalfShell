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
    static let window: TimeInterval = 3
    /// 이 시간 동안 입력 이벤트를 하나도 못 보면 모니터가 죽은 것으로 보고 재등록한다.
    private static let staleThreshold: TimeInterval = 60

    private var monitors: [Any] = []
    private var tapTimes: [Date] = []
    private var commandWasDown = false
    private var lastEventAt = Date.distantPast
    private var lastStuckLogAt = Date.distantPast
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
            MainActor.assumeIsolated { self?.noteReset(reason: "다른 키 입력") }
        }
        monitors = [flagMonitor, keyMonitor].compactMap { $0 }
        Log.write("[비상] Command \(Self.requiredTaps)번 연타 감지 시작")
    }

    /// 모니터가 조용히 죽는 경우에 대비한 자가 치유.
    ///
    /// 전역 이벤트 모니터는 객체가 살아 있어도 실제로는 이벤트를 못 받는 상태가
    /// 될 수 있다. `isRunning` 은 객체 유무만 보므로 그것을 잡아내지 못한다.
    /// 오랫동안 아무 이벤트도 못 봤다면 붙였다 떼서 되살린다. 재등록은 값이
    /// 싸므로 사용자가 자리를 비워 조용했던 경우에 걸려도 손해가 없다.
    func restartIfStale() {
        guard isRunning, isTrusted else { return }
        guard Date().timeIntervalSince(lastEventAt) > Self.staleThreshold else { return }
        Log.write("[비상] 오랫동안 입력 이벤트가 없어 감지기를 재등록한다")
        lastEventAt = Date()
        start()
    }

    func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        resetCount()
    }

    // MARK: - Private

    private func handleFlagsChanged(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // 실제로 "함께 눌린" 보조키만 본다.
        //
        // `.capsLock` 을 여기 넣었던 것이 버그였다. 그것은 누르고 있는 키가 아니라
        // **켜짐/꺼짐 상태**라서, Caps Lock 이 켜져 있으면 모든 이벤트에 플래그가
        // 붙어 카운트가 매번 초기화된다 — 연타가 영영 걸리지 않는다.
        // `.function` 도 외장 키보드에서 오탐이 잦아 제외한다.
        let chordModifiers: NSEvent.ModifierFlags = [.shift, .control, .option]
        guard flags.intersection(chordModifiers).isEmpty else {
            noteReset(reason: "다른 보조키")
            return
        }

        // "누름"만 세려고 직전 상태를 들고 있는데, 뗌 이벤트를 한 번이라도 놓치면
        // 눌림 상태가 계속 남아 **이후의 모든 누름이 무시된다.** 실사용에서 연타가
        // 통째로 먹히지 않은 경우가 있었고(로그에 카운트가 한 줄도 안 남았다),
        // 이 상태 고착이 유력한 원인이다. 마지막 이벤트로부터 오래 지났으면
        // 들고 있던 상태를 신뢰하지 않는다.
        let now = Date()
        if now.timeIntervalSince(lastEventAt) > Self.window {
            commandWasDown = false
        }
        lastEventAt = now

        let commandDown = flags.contains(.command)
        let ignoredWhileDown = commandDown && commandWasDown
        defer { commandWasDown = commandDown }
        if ignoredWhileDown, now.timeIntervalSince(lastStuckLogAt) > 5 {
            lastStuckLogAt = now
            Log.write("[비상] 눌림 상태가 남아 있어 이번 누름을 무시함(뗌 이벤트 유실 추정)")
        }
        guard commandDown, !commandWasDown else { return }  // 누르는 순간만 센다(뗄 때는 무시)

        tapTimes.append(now)
        tapTimes.removeAll { now.timeIntervalSince($0) > Self.window }

        guard tapTimes.count >= Self.requiredTaps else {
            // 진행 상황을 남긴다. 안 걸릴 때 원인을 알 수 있어야 한다.
            if tapTimes.count >= 2 {
                Log.write("[비상] Command \(tapTimes.count)/\(Self.requiredTaps)")
            }
            return
        }
        resetCount()
        Log.write("[비상] Command 연타 감지 → 내장 디스플레이 복구")
        onTrigger()
    }

    /// 세고 있던 중에 끊겼을 때만 기록한다. 평상시에는 로그를 채우지 않는다.
    private func noteReset(reason: String) {
        if tapTimes.count >= 2 {
            Log.write("[비상] 연타 카운트 초기화(\(tapTimes.count)회에서) — \(reason)")
        }
        resetCount()
    }

    private func resetCount() {
        tapTimes.removeAll()
    }
}
