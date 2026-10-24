import Foundation
import Testing
@testable import HalfShell

/// 유령 판별의 판단 로직 시험.
///
/// 입력은 **실측 사례 그대로**다(날짜는 POSTMORTEM 의 사건·실험 절과 대응한다).
/// 새 유령이나 새 실패가 관측되면 여기에 사례를 하나씩 더한다 — 그래야 다음 수정이
/// 과거에 맞혔던 판정을 깨뜨리지 않았는지 바로 알 수 있다.
@Suite("물리 링크 증거 판정")
struct EvidenceTests {
    @Test("깨어날 때의 유령은 물리 링크가 0 — 믿지 않는다", arguments: [
        ("9/5 유령 59·60", 2), ("9/11 유령 4·5", 2),
        ("9/19 유령 4·5", 2), ("10/24 유령 105·106", 2),
    ])
    func ghosts(_ name: String, _ listed: Int) {
        #expect(PhysicalLink.evidence(.count(0), externalCount: listed) == .unbacked, "\(name)")
    }

    @Test("진짜 외장은 링크 수가 맞는다")
    func realDisplays() {
        #expect(PhysicalLink.evidence(.count(2), externalCount: 2) == .backed)  // 10/14 4·5
        #expect(PhysicalLink.evidence(.count(1), externalCount: 1) == .backed)  // 10/22 5
    }

    @Test("장부가 전환 중이면 믿지 않는다 — 유령이 태어나는 구간이 바로 이때다")
    func notReady() {
        #expect(PhysicalLink.evidence(.notReady, externalCount: 1) == .unbacked)
    }

    @Test("장부가 없는 기기(Intel)는 판단하지 않는다 — 예전처럼 동작")
    func unsupported() {
        #expect(PhysicalLink.evidence(.unsupported, externalCount: 2) == .unavailable)
    }

    @Test("네이티브 1 + DisplayLink 1 은 즉시 증거가 아니다")
    func mixed() {
        #expect(PhysicalLink.evidence(.count(1), externalCount: 2) == .unbacked)
    }
}

@Suite("규칙 3의 관문 (사건 7)")
struct TrustGateTests {
    let t0 = Date(timeIntervalSince1970: 0)

    func waited(_ d: ExternalTrustGate.Decision) -> Double? {
        if case .wait(let w) = d { return w }; return nil
    }

    @Test("물리 증거가 있으면 즉시 통과")
    func backedAllowsImmediately() {
        var g = ExternalTrustGate()
        #expect(g.check(externals: [4, 5], evidence: .backed, now: t0) == .allow)
    }

    @Test("증거가 없으면 15초 유지될 때까지 기다린다 (유령 수명 실측 < 1초)")
    func unbackedWaitsForStability() throws {
        var g = ExternalTrustGate()
        _ = g.check(externals: [4, 5], evidence: .unbacked, now: t0)
        // 9/11 유령은 0.3초 만에 사라졌다
        let at03 = try #require(waited(g.check(externals: [4, 5], evidence: .unbacked, now: t0 + 0.3)))
        #expect(abs(at03 - 0.3) < 0.001)
        #expect(waited(g.check(externals: [4, 5], evidence: .unbacked, now: t0 + 14.9)) != nil)
        #expect(g.check(externals: [4, 5], evidence: .unbacked, now: t0 + 15) == .allow)
    }

    @Test("구성이 바뀌면 처음부터 다시 잰다 — 유령이 다른 유령으로 바뀐 것을 유지로 세지 않는다")
    func changeResets() {
        var g = ExternalTrustGate()
        _ = g.check(externals: [59, 60], evidence: .unbacked, now: t0)
        #expect(waited(g.check(externals: [4, 5], evidence: .unbacked, now: t0 + 15)) == 0)
    }

    @Test("증거가 생겼다 사라지면 다시 잰다")
    func evidenceGapResets() {
        var g = ExternalTrustGate()
        _ = g.check(externals: [4], evidence: .unbacked, now: t0)
        _ = g.check(externals: [4], evidence: .backed, now: t0 + 1)
        #expect(waited(g.check(externals: [4], evidence: .unbacked, now: t0 + 15)) == 0)
    }

    @Test("장부가 없는 기기는 즉시 통과")
    func unavailableAllows() {
        var g = ExternalTrustGate()
        #expect(g.check(externals: [4], evidence: .unavailable, now: t0) == .allow)
    }
}

@Suite("깨어남 복구 재시도의 양보 (사건 8)")
struct WakeRestorePolicyTests {
    @Test("10/22 — 재무장 + 진짜 외장이면 물러선다 (규칙 3과 다투지 않는다)")
    func yieldsToRule3() {
        #expect(WakeRestorePolicy.shouldYield(armed: true, externalCount: 1, evidence: .backed))
    }

    @Test("유령이 있으면 계속 지킨다 — 사건 3의 마지막 방어")
    func keepsGuardingAgainstGhosts() {
        #expect(!WakeRestorePolicy.shouldYield(armed: true, externalCount: 2, evidence: .unbacked))
    }

    @Test("외장이 없으면 계속 지킨다 — 규칙 1의 켜기가 실패했을 때 대비")
    func keepsGuardingWithNoExternals() {
        #expect(!WakeRestorePolicy.shouldYield(armed: true, externalCount: 0, evidence: .backed))
    }

    @Test("보류 중이거나 장부가 없으면 계속 지킨다")
    func keepsGuardingOtherwise() {
        #expect(!WakeRestorePolicy.shouldYield(armed: false, externalCount: 2, evidence: .backed))
        #expect(!WakeRestorePolicy.shouldYield(armed: true, externalCount: 1, evidence: .unavailable))
    }
}
