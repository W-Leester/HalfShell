import Foundation

/// ~/Library/Logs/HalfShell.log 에 append 하는 단순 파일 로거.
///
/// 화면이 하나도 없는 상태에서 무슨 일이 일어났는지는 사후에 확인하는 수밖에 없다.
/// 그 순간을 기록으로 남기는 것이 이 로거의 존재 이유다.
enum Log {
    static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("HalfShell.log")
    }()

    private static let queue = DispatchQueue(label: "dev.leester.halfshell.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()

    /// 직전 세대 로그. 회전할 때 현재 로그를 여기로 밀어둔다.
    static var previousFileURL: URL { fileURL.appendingPathExtension("1") }

    /// 로그가 무한정 커지지 않도록 실행할 때마다 1MB 넘으면 회전시킨다.
    ///
    /// 예전에는 그냥 지웠는데, 그러면 **사고 직후 앱을 재시작하는 순간 증거가
    /// 사라진다.** 실제로 배터리 사고 때는 몇 시간 만에 수천 줄이 쌓였다.
    /// 이 앱의 버그는 전부 로그로만 규명됐으므로 한 세대는 남겨둔다.
    static func startSession(_ note: String) {
        queue.async {
            let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))
                .flatMap { $0[.size] as? Int } ?? 0
            if size > 1_000_000 {
                try? FileManager.default.removeItem(at: previousFileURL)
                try? FileManager.default.moveItem(at: fileURL, to: previousFileURL)
            }
        }
        write("===== 시작: \(note) =====")
    }

    static func write(_ message: String) {
        queue.async {
            let line = "\(formatter.string(from: Date())) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }
}
