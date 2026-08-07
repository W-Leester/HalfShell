// 앱 아이콘(AppIcon.icns) 생성기. build.sh에서 호출한다.
// 1024x1024 PNG를 그린 뒤 sips/iconutil로 .icns를 만든다.
import AppKit
import Foundation

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let size: CGFloat = 1024

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

guard let context = NSGraphicsContext.current?.cgContext else {
    fatalError("그래픽 컨텍스트를 만들 수 없습니다")
}

// macOS 앱 아이콘 관례: 1024 캔버스 안에 약 82% 크기의 둥근 사각형
let inset = size * 0.09
let squircle = NSBezierPath(
    roundedRect: NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2),
    xRadius: size * 0.185,
    yRadius: size * 0.185
)

context.saveGState()
squircle.addClip()
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.21, alpha: 1),
    NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.09, alpha: 1),
])!
gradient.draw(in: NSRect(x: 0, y: 0, width: size, height: size), angle: -90)
context.restoreGState()

// 노트북: 열린 뚜껑(꺼진 화면) + 받침대. 외장 화면은 뒤에 켜져 있는 모습.
let centerX = size / 2

// 뒤쪽 외장 모니터 (켜짐 - 파란 빛)
let monitorWidth = size * 0.46
let monitorHeight = size * 0.30
let monitorRect = NSRect(
    x: centerX - monitorWidth / 2,
    y: size * 0.50,
    width: monitorWidth,
    height: monitorHeight
)
let monitorPath = NSBezierPath(roundedRect: monitorRect, xRadius: size * 0.018, yRadius: size * 0.018)
NSColor(calibratedRed: 0.25, green: 0.55, blue: 0.95, alpha: 1).setFill()
monitorPath.fill()

// 모니터 목/받침
let neckRect = NSRect(x: centerX - size * 0.035, y: size * 0.455, width: size * 0.07, height: size * 0.05)
NSColor(calibratedWhite: 0.55, alpha: 1).setFill()
NSBezierPath(rect: neckRect).fill()

// 앞쪽 노트북 뚜껑 (꺼짐 - 어두운 화면)
let lidWidth = size * 0.40
let lidHeight = size * 0.26
let lidRect = NSRect(
    x: centerX - lidWidth / 2,
    y: size * 0.245,
    width: lidWidth,
    height: lidHeight
)
let lidPath = NSBezierPath(roundedRect: lidRect, xRadius: size * 0.014, yRadius: size * 0.014)
NSColor(calibratedWhite: 0.82, alpha: 1).setFill()
lidPath.fill()

// 꺼진 화면 (뚜껑 안쪽)
let screenInset = size * 0.016
let screenRect = lidRect.insetBy(dx: screenInset, dy: screenInset)
NSColor(calibratedWhite: 0.13, alpha: 1).setFill()
NSBezierPath(roundedRect: screenRect, xRadius: size * 0.008, yRadius: size * 0.008).fill()

// 노트북 하단 베이스 (열린 상태를 나타내는 사다리꼴)
let baseTop = lidRect.minY
let basePath = NSBezierPath()
basePath.move(to: NSPoint(x: centerX - lidWidth / 2 - size * 0.045, y: baseTop - size * 0.055))
basePath.line(to: NSPoint(x: centerX + lidWidth / 2 + size * 0.045, y: baseTop - size * 0.055))
basePath.line(to: NSPoint(x: centerX + lidWidth / 2, y: baseTop))
basePath.line(to: NSPoint(x: centerX - lidWidth / 2, y: baseTop))
basePath.close()
NSColor(calibratedWhite: 0.72, alpha: 1).setFill()
basePath.fill()

// 꺼짐을 나타내는 사선 (화면 위를 가로지름)
let slash = NSBezierPath()
slash.move(to: NSPoint(x: screenRect.minX + size * 0.035, y: screenRect.minY + size * 0.03))
slash.line(to: NSPoint(x: screenRect.maxX - size * 0.035, y: screenRect.maxY - size * 0.03))
slash.lineWidth = size * 0.022
slash.lineCapStyle = .round
NSColor(calibratedRed: 1.0, green: 0.35, blue: 0.35, alpha: 1).setStroke()
slash.stroke()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
else {
    fatalError("PNG 인코딩 실패")
}

let outputURL = URL(fileURLWithPath: outputDir).appendingPathComponent("icon-1024.png")
try png.write(to: outputURL)
print("아이콘 생성: \(outputURL.path)")
