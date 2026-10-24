import Foundation
import SwiftUI

/// 앱 안에서 고른 언어로 문자열을 조회한다.
///
/// macOS 가 알아서 골라 주는 것(`Bundle.main`)에 맡기면 시스템 언어만 따를 수
/// 있다. 사용자가 앱 안에서 고르게 하려면 **번역 묶음을 직접 지정**해야 한다.
///
/// `AppleLanguages` 를 덮어쓰는 흔한 수법은 쓰지 않았다. 그 방식은 이미 그려진
/// 화면을 갈아끼우지 못해 **앱을 재시작해야** 하는데, 이 앱의 재시작은 종료 시
/// 내장 복구 → 시작 시 규칙 3 재적용을 거치므로 화면이 한 번 깜빡인다.
/// 디스플레이를 만지는 앱이 언어를 바꾸겠다고 화면을 흔드는 것은 곤란하다.
///
/// 대신 조회를 이 한 곳으로 모았다. ``L10n/shared`` 가 바뀌면 이를 관찰하는
/// 화면들이 다시 그려지고, 언어가 **즉시** 바뀐다.
enum Language: String, CaseIterable, Identifiable {
    case system, korean, english

    var id: String { rawValue }

    /// `.lproj` 폴더 이름. 시스템을 따를 때는 지정하지 않는다.
    var code: String? {
        switch self {
        case .system: return nil
        case .korean: return "ko"
        case .english: return "en"
        }
    }

    /// 언어 이름은 **그 언어로** 적는다. 한국어 화면에서 "영어"라고 쓰면
    /// 영어만 읽는 사용자가 자기 언어를 못 찾는다.
    @MainActor var displayName: String {
        switch self {
        case .system: return L("시스템 설정 따름")
        case .korean: return "한국어"
        case .english: return "English"
        }
    }
}

@MainActor
final class L10n: ObservableObject {
    static let shared = L10n()

    private static let key = "language"

    @Published var language: Language {
        didSet {
            guard language != oldValue else { return }
            UserDefaults.standard.set(language.rawValue, forKey: Self.key)
            Log.write("[설정] 언어 = \(language.rawValue)")
        }
    }

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.key)
        language = saved.flatMap(Language.init(rawValue:)) ?? .system
    }

    /// 실제로 보이고 있는 언어의 코드("ko"/"en"). 웹 페이지를 같은 언어로 열 때 쓴다.
    /// 시스템을 따를 때는 macOS 가 이 앱의 번역 중에서 고른 것을 그대로 쓴다.
    var resolvedCode: String {
        if let code = language.code { return code }
        return Bundle.main.preferredLocalizations.first == "ko" ? "ko" : "en"
    }

    /// 조회에 쓸 번역 묶음.
    ///
    /// 고른 언어의 `.lproj` 를 찾지 못하면 `Bundle.main` 으로 떨어진다 —
    /// 그러면 최소한 시스템 언어로는 보인다. 번역이 통째로 사라지는 일은 없다.
    var bundle: Bundle {
        guard let code = language.code,
              let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              let bundle = Bundle(path: path)
        else { return .main }
        return bundle
    }
}

/// 번역된 문자열. 키는 한글 원문이다.
///
/// 키를 그대로 기본값으로 넘기므로, 번역이 빠진 항목은 **한글로 떨어진다.**
/// 영어권 사용자에게 빈 문자열이나 `menu.quit` 같은 날것이 보이는 일은 없다.
///
/// `SwiftUI` 의 `Text("리터럴")` 이 자동으로 하는 일을 굳이 손으로 하는 이유는
/// 하나다 — 그쪽은 `Bundle.main` 만 보므로 앱 안에서 언어를 고를 수 없다.
@MainActor
func L(_ key: String, _ arguments: CVarArg...) -> String {
    let format = L10n.shared.bundle.localizedString(forKey: key, value: key, table: nil)
    return arguments.isEmpty ? format : String(format: format, arguments: arguments)
}
