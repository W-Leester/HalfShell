import Testing
@testable import HalfShell

/// 탈출구 원칙 — 화면 복구 단축키가 준비되지 않았으면 유일한 화면을 끄지 않는다.
@Suite("탈출구 원칙 (10/24 권한 유실)")
struct EscapePolicyTests {
    @Test("권한이 없으면 끄지 않는다")
    func noPermissionNoTurnOff() {
        #expect(!EscapePolicy.mayTurnOff(escapeReady: false))
        #expect(EscapePolicy.mayTurnOff(escapeReady: true))
    }

    @Test("10/24 — 권한이 풀린 채 내장이 꺼져 있으면(뚜껑 열림) 되살린다")
    func restoresWhenEscapeLost() {
        #expect(EscapePolicy.mustRestore(escapeReady: false, builtinOff: true, lidClosed: false))
    }

    @Test("뚜껑이 닫혀 있으면 손대지 않는다 — 꺼진 것이 정상(클램쉘, 사건 5)")
    func leavesClamshellAlone() {
        #expect(!EscapePolicy.mustRestore(escapeReady: false, builtinOff: true, lidClosed: true))
    }

    @Test("권한이 있거나 이미 켜져 있으면 할 일이 없다")
    func nothingToDo() {
        #expect(!EscapePolicy.mustRestore(escapeReady: true, builtinOff: true, lidClosed: false))
        #expect(!EscapePolicy.mustRestore(escapeReady: false, builtinOff: false, lidClosed: false))
    }
}
