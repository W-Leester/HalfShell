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

    /// 한 파일의 상한. 넘으면 직전 세대로 밀고 새로 시작한다.
    private static let sizeLimit = 1_000_000
    /// 이 횟수마다 크기를 확인한다. 매번 확인하면 파일 조회가 낭비다.
    private static let checkEvery = 500
    private static var writeCount = 0

    static func startSession(_ note: String) {
        queue.async { rotateIfNeeded() }
        write("===== 시작: \(note) =====")
    }

    /// 1MB 를 넘으면 회전시킨다.
    ///
    /// 예전에는 그냥 지웠는데, 그러면 **사고 직후 앱을 재시작하는 순간 증거가
    /// 사라진다.** 실제로 배터리 사고 때는 몇 시간 만에 수천 줄이 쌓였다.
    /// 이 앱의 버그는 전부 로그로만 규명됐으므로 한 세대는 남겨둔다.
    ///
    /// 시작할 때만 검사하면 재부팅 없이 오래 켜둔 경우에 상한이 지켜지지 않는다.
    /// (이 기기도 24일 연속 가동한 적이 있다) 그래서 쓰는 도중에도 주기적으로 본다.
    private static func rotateIfNeeded() {
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))
            .flatMap { $0[.size] as? Int } ?? 0
        guard size > sizeLimit else { return }
        try? FileManager.default.removeItem(at: previousFileURL)
        try? FileManager.default.moveItem(at: fileURL, to: previousFileURL)
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
            writeCount += 1
            if writeCount >= checkEvery {
                writeCount = 0
                rotateIfNeeded()
            }
        }
    }
}
