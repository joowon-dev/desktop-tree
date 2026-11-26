// Desktop Tree — macOS 셸.
//
// 트리와 방울의 규칙은 전부 web/ 안의 JS 다(src/game/). 이 파일은 그 엔진이 못 하는 것만 한다:
//   · 트리만 한 크기의 투명 창 (방울 위에서만 클릭을 받고 나머지는 밑의 앱으로 통과)
//   · 지금 떠 있는 창의 목록 (CGWindowList — 권한 없음)
//   · 방울을 누르면 그 창을 닫고 · 접고 · 키우기 (손쉬운 사용 API — **권한이 필요하다**)
//   · 메뉴 막대
//
// 바탕화면 츤데레(../desktop-tsundere)의 셸과 골격이 같다.

import AppKit
import ApplicationServices
import notify
import ServiceManagement
import WebKit

// MARK: - 상수

private let stateKey = "state"
private let promptedKey = "askedForAccess"
/// 끌어다 놓은 자리(트리 밑동의 가운데, 화면 좌표). 없으면 메뉴에서 고른 구석이다.
private let anchorKey = "anchor"
private let webScheme = "tree"

/// 새 버전이 있는지 물어보는 곳. 태그를 밀면 CI 가 여기에 릴리스를 올린다.
private let releaseAPI = "https://api.github.com/repos/joowon-dev/desktop-tree/releases/latest"
private let releasePage = "https://joowonkoh.com/playground/desktop-tree"
/// 자동 업데이트가 받아 가는 것은 zip 이다 — dmg 를 마운트해 자기를 갈아 끼우면 실패할 자리가 너무 많다.
private let macAssetSuffix = "-mac.zip"
private let updateCheckInterval: TimeInterval = 24 * 60 * 60
private let firstUpdateCheckDelay: TimeInterval = 20

/// "v1.10.0" 이 "1.9.0" 보다 높다. 문자열로 비교하면 거꾸로 나온다.
func isNewerVersion(_ candidate: String, than current: String) -> Bool {
    func parts(_ text: String) -> [Int] {
        text.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            .split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }
    let a = parts(candidate), b = parts(current)
    for i in 0..<max(a.count, b.count) {
        let x = i < a.count ? a[i] : 0
        let y = i < b.count ? b[i] : 0
        if x != y { return x > y }
    }
    return false
}

@discardableResult
private func run(_ tool: String, _ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return -1 }
    process.waitUntilExit()
    return process.terminationStatus
}
/// 기준 판의 크기(pt). src/game/tree.js 의 BOARD 와 같아야 한다.
private let boardSize = CGSize(width: 460, height: 560)
/// 트리의 크기(기준 판에 곱하는 배율)의 범위. src/game/tree.js 의 SCALE 과 같아야 한다.
private let scaleRange: ClosedRange<CGFloat> = 0.3...1.6
/// 메뉴에서 고르는 크기. 그 사이는 별을 끌어서 정한다.
private let scalePresets: [(String, Double)] = [("아주 작게", 0.3), ("작게", 0.55), ("조금 작게", 0.8), ("보통", 1.0), ("크게", 1.3)]
/// 마우스 자리를 보는 간격. 방울 위에 올라왔다·나갔다가 바뀔 때만 렌더러를 깨운다.
private let pointerInterval: TimeInterval = 1.0 / 30
/// 창의 목록을 다시 읽는 간격.
private let watchInterval: TimeInterval = 1.0
/// 이보다 작은 창은 창으로 안 친다(도구 막대·말풍선 같은 것).
private let smallestWindow = CGSize(width: 160, height: 100)
/// 키울 때 창이 자라는 시간과 걸음 수.
private let growTime: TimeInterval = 0.22
private let growSteps = 10

private let debugging = ProcessInfo.processInfo.environment["TREE_DEBUG"] != nil

func debugLog(_ text: String) {
    guard debugging else { return }
    let stamp = String(format: "%.3f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000))
    FileHandle.standardError.write("[tree \(stamp)] \(text)\n".data(using: .utf8)!)
}

/// 값을 JS 리터럴로 만든다. **손으로 따옴표를 붙이지 않는다.**
func jsLiteral(_ value: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]),
          let text = String(data: data, encoding: .utf8) else { return "null" }
    return text
}

/// 손쉬운 사용 API 의 창(AXUIElement)이 윈도우 서버의 몇 번 창인지. 공개 API 에는 이 다리가 없다 —
/// 없으면 창의 자리와 크기로 맞춰 보는 수밖에 없고, 같은 자리에 겹친 창을 못 가른다.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

// MARK: - 손쉬운 사용 API 를 읽고 쓰는 작은 것들

private func axValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var out: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, attribute as CFString, &out) == .success ? out : nil
}

private func axBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
    (axValue(element, attribute) as? NSNumber)?.boolValue
}

private func axChild(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
    guard let value = axValue(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

/// 창의 자리와 크기. 손쉬운 사용 API 의 좌표는 **주 화면의 왼쪽 위가 원점**이다.
private func axFrame(_ element: AXUIElement) -> CGRect? {
    guard let position = axValue(element, kAXPositionAttribute), let size = axValue(element, kAXSizeAttribute),
          CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
    var origin = CGPoint.zero, extent = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
          AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
    return CGRect(origin: origin, size: extent)
}

private func axSetFrame(_ element: AXUIElement, _ frame: CGRect) {
    var origin = frame.origin, extent = frame.size
    if let value = AXValueCreate(.cgPoint, &origin) {
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }
    if let value = AXValueCreate(.cgSize, &extent) {
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
    }
}

// MARK: - 떠 있는 창들

/**
 지금 떠 있는 창의 목록을 쥐고 있고, 방울이 눌리면 그 창에 일을 시킨다.

 손쉬운 사용 API 는 상대 앱이 대답할 때까지 기다린다(멈춘 앱이면 몇 초). 그래서 전부 **따로 둔 줄**에서
 돈다 — 메인에서 부르면 그동안 트리가 얼어붙는다.
 */
final class WindowWatcher {
    private struct Seen {
        let id: CGWindowID
        let pid: pid_t
        let app: String
    }

    private let queue = DispatchQueue(label: "dev.joowonkoh.desktop-tree.windows")
    private let ownPid = getpid()
    private var timer: DispatchSourceTimer?

    private var known: [CGWindowID: Seen] = [:]
    /// 창 번호 → 그 창을 가리키는 손쉬운 사용 API 의 손잡이. 권한이 있을 때만 채워진다.
    private var elements: [CGWindowID: AXUIElement] = [:]
    /// 손잡이를 한 번 찾아봤는데 없던 창. 매초 다시 묻지 않는다(누를 때는 다시 찾는다).
    private var searched: Set<CGWindowID> = []
    private var minimized: Set<CGWindowID> = []
    /// 우리가 키운 창 → 키우기 전의 자리. 초록을 다시 누르면 여기로 돌아간다.
    private var grown: [CGWindowID: CGRect] = [:]
    private var lastSent = ""
    private var quietUntil = Date.distantPast

    /// 목록이 바뀌면 메인에서 불린다. quiet 는 「떨어지는 연출 없이 조용히」.
    var onChange: (([[String: Any]], Bool) -> Void)?

    func start() {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: watchInterval, leeway: .milliseconds(200))
        source.setEventHandler { [weak self] in self?.tick() }
        source.resume()
        timer = source
    }

    /// 데스크탑(Space)을 옮기면 창이 한꺼번에 바뀐다. 그건 「닫힌 것」이 아니니 조용히 바꾼다.
    func spaceChanged() {
        queue.async {
            self.quietUntil = Date().addingTimeInterval(1.5)
            self.tick()
        }
    }

    /// 렌더러가 방금 켜졌다 — 바뀐 게 없어도 한 번 보낸다.
    func resend() {
        queue.async {
            self.lastSent = ""
            self.tick()
        }
    }

    // MARK: 읽기

    private func onScreen() -> [Seen] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        var out: [Seen] = []
        for info in raw {
            guard (info[kCGWindowLayer as String] as? Int) == 0, // 보통 창만. 메뉴 막대·Dock·오버레이는 층이 다르다
                  let number = info[kCGWindowNumber as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? Int, pid_t(pid) != ownPid,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  frame.width >= smallestWindow.width, frame.height >= smallestWindow.height else { continue }
            out.append(Seen(id: CGWindowID(number), pid: pid_t(pid),
                            app: info[kCGWindowOwnerName as String] as? String ?? ""))
        }
        return out
    }

    /// 한 앱의 창들을 손쉬운 사용 API 로 훑어 손잡이를 챙긴다.
    private func resolve(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.6)
        guard let windows = axValue(app, kAXWindowsAttribute) as? [AXUIElement] else { return }
        for element in windows {
            var id: CGWindowID = 0
            guard _AXUIElementGetWindow(element, &id) == .success, id != 0 else { continue }
            AXUIElementSetMessagingTimeout(element, 0.6)
            elements[id] = element
        }
    }

    private func tick() {
        let trusted = AXIsProcessTrusted()
        var next: [CGWindowID: Seen] = [:]
        for window in onScreen() {
            next[window.id] = window
            minimized.remove(window.id)
        }
        // 화면에서 사라진 창: Dock 으로 접힌 것이면 남기고(불만 꺼진다), 아니면 닫힌 것이다.
        for (id, window) in known where next[id] == nil {
            guard trusted, let element = elements[id], axBool(element, kAXMinimizedAttribute) == true else { continue }
            next[id] = window
            minimized.insert(id)
        }
        known = next
        elements = elements.filter { next[$0.key] != nil }
        grown = grown.filter { next[$0.key] != nil }
        minimized = minimized.filter { next[$0] != nil }
        searched = searched.filter { next[$0] != nil }

        if trusted {
            let missing = next.values.filter { elements[$0.id] == nil && !searched.contains($0.id) }
            for pid in Set(missing.map(\.pid)) { resolve(pid: pid) }
            for window in missing { searched.insert(window.id) }
        }
        publish()
    }

    private func publish() {
        let list: [[String: Any]] = known.values.sorted { $0.id < $1.id }.map {
            ["id": Int($0.id), "pid": Int($0.pid), "app": $0.app,
             "min": minimized.contains($0.id), "big": grown[$0.id] != nil]
        }
        let text = jsLiteral(list)
        guard text != lastSent else { return }
        lastSent = text
        let quiet = Date() < quietUntil
        debugLog("창 \(list.count)개\(quiet ? " (조용히)" : "") — \(known.values.map { "\($0.app)#\($0.id)" }.sorted().joined(separator: ", "))")
        DispatchQueue.main.async { self.onChange?(list, quiet) }
    }

    // MARK: 시키기

    /// 방울이 눌렸다. done 은 메인에서 불린다: "ok" · "denied"(권한이 없다) · "fail"(그 창이 말을 안 듣는다).
    func act(id: CGWindowID, kind: String, done: @escaping (String) -> Void) {
        queue.async {
            let result = self.perform(id: id, kind: kind)
            debugLog("누름 #\(id) \(kind) → \(result)")
            DispatchQueue.main.async { done(result) }
            guard result == "ok" else { return }
            // 닫히고 접히는 데는 시간이 걸린다. 1초를 기다리지 않고 바로바로 다시 본다.
            for delay in [0.12, 0.35, 0.7] {
                self.queue.asyncAfter(deadline: .now() + delay) { self.tick() }
            }
        }
    }

    private func perform(id: CGWindowID, kind: String) -> String {
        guard AXIsProcessTrusted() else { return "denied" }
        guard let window = known[id] else { return "fail" }
        if elements[id] == nil { resolve(pid: window.pid) }
        guard let element = elements[id] else { return "fail" }

        switch kind {
        case "red":
            // 창의 진짜 빨간 단추를 누른다. 저장 안 한 문서면 그 앱이 평소처럼 묻는다 — 우리는 강제로 닫지 않는다.
            guard let button = axChild(element, kAXCloseButtonAttribute),
                  AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else { return "fail" }
        case "yellow":
            let folded = axBool(element, kAXMinimizedAttribute) ?? false
            let value: CFBoolean = folded ? kCFBooleanFalse : kCFBooleanTrue
            guard AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, value) == .success else { return "fail" }
            if folded { bringForward(element, pid: window.pid) }
        case "green":
            if axBool(element, kAXMinimizedAttribute) == true {
                AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                Thread.sleep(forTimeInterval: 0.45) // Dock 에서 나오는 동안에는 크기를 바꿔도 안 먹는다
            }
            guard let now = axFrame(element) else { return "fail" }
            let full = Self.roomFor(now)
            bringForward(element, pid: window.pid)
            if let before = grown[id], Self.close(now, full) {
                grown[id] = nil
                glide(element, from: now, to: before)
            } else {
                grown[id] = now
                glide(element, from: now, to: full)
            }
        default:
            return "fail"
        }
        return "ok"
    }

    private func bringForward(_ element: AXUIElement, pid: pid_t) {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        DispatchQueue.main.async { NSRunningApplication(processIdentifier: pid)?.activate() }
    }

    /// 창이 한 번에 튀지 않고 자라게, 몇 걸음에 나눠 옮긴다. 느린 앱이면 걸음을 건너뛰고 끝으로 간다.
    private func glide(_ element: AXUIElement, from: CGRect, to: CGRect) {
        let pause = growTime / Double(growSteps)
        for step in 1..<growSteps {
            let began = Date()
            let t = CGFloat(step) / CGFloat(growSteps)
            let eased = 1 - (1 - t) * (1 - t) * (1 - t)
            axSetFrame(element, CGRect(
                x: from.minX + (to.minX - from.minX) * eased, y: from.minY + (to.minY - from.minY) * eased,
                width: from.width + (to.width - from.width) * eased, height: from.height + (to.height - from.height) * eased))
            let took = Date().timeIntervalSince(began)
            if took > pause * 2 { break }
            if took < pause { Thread.sleep(forTimeInterval: pause - took) }
        }
        axSetFrame(element, to)
        axSetFrame(element, to) // 자리를 먼저 옮기면 크기가 화면에 걸려 잘리는 앱이 있다. 한 번 더.
    }

    private static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 24 && abs(a.minY - b.minY) < 24 && abs(a.width - b.width) < 24 && abs(a.height - b.height) < 24
    }

    /// 그 창이 있는 화면에서 메뉴 막대와 Dock 을 뺀 자리(손쉬운 사용 API 의 좌표로).
    private static func roomFor(_ frame: CGRect) -> CGRect {
        let screens = NSScreen.screens
        let tall = (screens.first { $0.frame.origin == .zero } ?? screens.first)?.frame.height ?? 0
        let rooms = screens.map { screen -> CGRect in
            let inner = screen.visibleFrame
            return CGRect(x: inner.minX, y: tall - inner.maxY, width: inner.width, height: inner.height)
        }
        let middle = CGPoint(x: frame.midX, y: frame.midY)
        return rooms.first { $0.contains(middle) } ?? rooms.first ?? frame
    }
}

// MARK: - 창

/// 트리가 사는 창. 클릭을 받아도 앞으로 나서지 않는다(쓰던 앱의 포커스를 뺏지 않는다).
final class TreePanel: NSPanel {
    /// 눌렀다 · 누른 채 움직였다 · 뗐다.
    var onPress: (() -> Void)?
    var onDrag: (() -> Void)?
    var onRelease: (() -> Void)?
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 마우스는 웹뷰까지 내려보내지 않는다 — 어느 방울인지는 셸이 이미 알고 있다.
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown: onPress?()
        case .leftMouseDragged: onDrag?()
        case .leftMouseUp: onRelease?()
        case .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .scrollWheel: break
        default: super.sendEvent(event)
        }
    }
}

/// file:// 로 열면 ES 모듈 import 가 막힌다. 커스텀 스킴으로 번들 Resources/web 을 내준다.
/// `/icon/<pid>` 는 그 앱의 아이콘이다(이름표에 붙는다).
final class WebAssetHandler: NSObject, WKURLSchemeHandler {
    private let root: URL
    init(root: URL) { self.root = root }

    private static let mimeTypes = [
        "html": "text/html", "js": "text/javascript", "css": "text/css", "json": "application/json", "png": "image/png",
    ]

    private func icon(pid: pid_t) -> Data? {
        guard let image = NSRunningApplication(processIdentifier: pid)?.icon else { return nil }
        let side = 64
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        var data: Data?
        var mime = "application/octet-stream"
        if url.path.hasPrefix("/icon/") {
            data = Int32(url.lastPathComponent).flatMap { icon(pid: $0) }
            mime = "image/png"
        } else {
            let file = root.appendingPathComponent(url.path).standardized
            // 번들 밖으로 나가는 경로는 거절한다.
            if file.path.hasPrefix(root.path) { data = try? Data(contentsOf: file) }
            mime = Self.mimeTypes[file.pathExtension] ?? mime
        }
        guard let body = data else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: body.count, textEncodingName: "utf-8"))
        task.didReceive(body)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

// MARK: - 앱

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate, WKScriptMessageHandler {
    private var window: TreePanel!
    private var webView: WKWebView!
    private var statusItem: NSStatusItem!
    private let watcher = WindowWatcher()

    /// 렌더러가 알려 준 설정. 셸은 이걸 메뉴에 적고, 창의 자리와 크기를 맞춘다.
    private var settings: [String: Any] = [:]
    private var windowCount = 0

    /// 누를 수 있는 동그라미들(웹 좌표: 창의 왼쪽 위가 원점). 렌더러가 알려 준다.
    private var hits: [(key: String, center: CGPoint, radius: CGFloat)] = []
    private var hovered: String?
    /// 잡고 끌 수 있는 데(웹 좌표). 방울이 아닌 트리의 몸통이다.
    private var body: [CGRect] = []
    private var overBody = false
    /// 끄는 중이면: 잡은 순간의 마우스 자리와 창의 자리.
    private var drag: (mouse: NSPoint, origin: NSPoint)?
    /// 크기를 정하는 손잡이 — 꼭대기 별(웹 좌표). 잡고 끌면 밑동은 그대로 있고 별이 마우스를 따라온다.
    private var grip: (center: CGPoint, radius: CGFloat)?
    /// 별이 밑동에서 얼마나 높이 있나(창 높이에 대한 비율). 판의 모양이 정하는 값이라 크기가 바뀌어도 같다.
    private var gripRatio: CGFloat = 0.886
    private var overGrip = false
    /// 크기를 바꾸는 중이면: 별과 마우스의 높이 차, 밑동의 가운데(화면 좌표).
    private var resize: (offset: CGFloat, base: NSPoint)?
    /// 끌어서 정한 크기. 렌더러가 설정으로 되돌려 줄 때까지 이 값을 쓴다.
    private var liveScale: CGFloat?
    private var lastSettingsOpen = Date.distantPast

    private var updateVersion: String?
    private var updateAsset: URL?
    private var updateNote: String?
    private var updating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()
        buildStatusItem()
        if debugging { registerDebugTriggers() }

        watcher.onChange = { [weak self] list, quiet in
            self?.windowCount = list.count
            self?.call("__treeWindows", list, quiet)
        }
        watcher.start()

        let timer = Timer(timeInterval: pointerInterval, repeats: true) { [weak self] _ in self?.checkPointer() }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.watcher.spaceChanged() }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.place() }
        // Dock 을 옮기거나 자동 숨김을 바꾸면 화면 크기는 그대로인데 「안쪽」이 달라진다. 싸게 가끔 본다.
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.place() }
        scheduleUpdateChecks()
        debugLog("손쉬운 사용 권한 \(AXIsProcessTrusted() ? "있음" : "없음")")
    }

    // MARK: 창

    /// 트리가 설 자리: 끌어다 놓은 데가 있으면 거기, 없으면 Dock 위 화면의 오른쪽(또는 왼쪽) 구석.
    private func treeFrame() -> NSRect {
        let scale = currentScale
        let width = boardSize.width * scale, height = boardSize.height * scale
        if let saved = UserDefaults.standard.array(forKey: anchorKey) as? [Double], saved.count == 2 {
            return Self.keptOnScreen(NSRect(x: saved[0] - width / 2, y: saved[1], width: width, height: height))
        }
        let room = Self.primaryScreen.visibleFrame
        let x = settings["spot"] as? String == "left" ? room.minX + 8 : room.maxX - width - 8
        return NSRect(x: x, y: room.minY, width: width, height: height)
    }

    private var currentScale: CGFloat {
        let saved = (settings["scale"] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 1
        return min(max(liveScale ?? saved, scaleRange.lowerBound), scaleRange.upperBound)
    }

    /// 트리가 화면 밖으로 사라지지 않게 한다 — 가장 많이 걸친 화면 안으로 밀어 넣는다(모니터를 뽑았을 때도).
    private static func keptOnScreen(_ frame: NSRect) -> NSRect {
        func overlap(_ screen: NSScreen) -> CGFloat {
            let shared = screen.frame.intersection(frame)
            return shared.isNull ? 0 : shared.width * shared.height
        }
        let screen = NSScreen.screens.max { overlap($0) < overlap($1) } ?? primaryScreen
        let room = overlap(screen) > 0 ? screen.visibleFrame : primaryScreen.visibleFrame
        var out = frame
        out.origin.x = min(max(out.minX, room.minX), max(room.minX, room.maxX - out.width))
        out.origin.y = min(max(out.minY, room.minY), max(room.minY, room.maxY - out.height))
        return out
    }

    private func place() {
        guard drag == nil, resize == nil else { return } // 끄는 동안에는 손이 자리와 크기를 정한다
        let frame = treeFrame()
        if window.frame != frame { window.setFrame(frame, display: true) }
        if settings["hidden"] as? Bool == true {
            window.orderOut(nil)
            setHovered(nil)
            window.ignoresMouseEvents = true
        } else if !window.isVisible {
            window.orderFrontRegardless()
        }
    }

    private func buildWindow() {
        window = TreePanel(contentRect: treeFrame(), styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true // 방울 위에 올라왔을 때만 잠깐 푼다(checkPointer)
        window.hidesOnDeactivate = false
        window.isFloatingPanel = true
        window.level = .init(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        window.onPress = { [weak self] in self?.pressed() }
        window.onDrag = { [weak self] in self?.dragged() }
        window.onRelease = { [weak self] in self?.released() }

        let config = WKWebViewConfiguration()
        let web = Bundle.main.resourceURL!.appendingPathComponent("web")
        config.setURLSchemeHandler(WebAssetHandler(root: web), forURLScheme: webScheme)
        config.userContentController.add(self, name: "tree")
        config.userContentController.addUserScript(
            WKUserScript(source: bridgeScript(), injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )

        webView = WKWebView(frame: window.contentView!.bounds, configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.setValue(false, forKey: "drawsBackground") // 웹뷰 배경을 지워야 창의 투명이 산다
        webView.load(URLRequest(url: URL(string: "\(webScheme)://app/renderer/index.html")!))

        window.contentView?.addSubview(webView)
        window.orderFrontRegardless() // 포커스는 가져가지 않는다
    }

    /// 저장해 둔 것. 렌더러가 준 JSON 을 **그대로** 들고 있다가 그대로 돌려준다.
    private func savedStateLiteral() -> String {
        guard let text = UserDefaults.standard.string(forKey: stateKey),
              let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) else { return "null" }
        return jsLiteral(value)
    }

    private func bridgeScript() -> String {
        return """
        (() => {
          const post = (m) => window.webkit.messageHandlers.tree.postMessage(m)
          const hook = (name) => (handler) => { window[name] = handler }
          window.sneaky = {
            platform: 'mac',
            getState: () => Promise.resolve(\(savedStateLiteral())),
            saveState: (s) => post({ type: 'state', json: JSON.stringify(s) }),
            setSettings: (s) => post({ type: 'settings', settings: s }),
            setHits: (list) => post({ type: 'hits', list: list.map((h) => ({ key: String(h.key), x: +h.x, y: +h.y, r: +h.r })) }),
            setGrip: (g) => post({ type: 'grip', x: +g.x, y: +g.y, r: +g.r }),
            setBody: (list) => post({ type: 'body', list: list.map((b) => ({ x: +b.x, y: +b.y, w: +b.w, h: +b.h })) }),
            ready: () => post({ type: 'ready' }),
            onSet: hook('__treeSet'),
            onWindows: hook('__treeWindows'),
            onHover: hook('__treeHover'),
            onPressed: hook('__treePressed'),
            onMoved: hook('__treeMoved'),
            onGrip: hook('__treeGrip'),
          }
          // 웹뷰는 콘솔이 안 보인다. 오류만이라도 셸의 stderr 로 흘려보낸다.
          window.addEventListener('error', (e) => post({ type: 'log', text: `${e.message} (${e.filename}:${e.lineno})` }))
          window.addEventListener('unhandledrejection', (e) => post({ type: 'log', text: `reject ${e.reason}` }))
          console.error = (...args) => post({ type: 'log', text: args.join(' ') })
        })()
        """
    }

    private func call(_ name: String, _ arguments: Any...) {
        let list = arguments.map(jsLiteral).joined(separator: ", ")
        webView.evaluateJavaScript("window.\(name) && window.\(name)(\(list))")
    }

    // MARK: 마우스

    /// 마우스의 자리를 웹 좌표(창의 왼쪽 위가 원점)로. 창 밖이면 nil. 자리만 묻는다 — 권한이 필요 없다.
    private func mouseInWindow() -> CGPoint? {
        let frame = window.frame
        let mouse = NSEvent.mouseLocation
        guard frame.contains(mouse) else { return nil }
        return CGPoint(x: mouse.x - frame.minX, y: frame.maxY - mouse.y)
    }

    private func hit(at point: CGPoint?) -> String? {
        guard let point else { return nil }
        // 트리가 작으면 누를 수 있는 동그라미끼리 겹친다. 그중 가장 가까운 것이다.
        return hits.map { (key: $0.key, far: hypot($0.center.x - point.x, $0.center.y - point.y), radius: $0.radius) }
            .filter { $0.far <= $0.radius }.min { $0.far < $1.far }?.key
    }

    private func onGrip(_ point: CGPoint?) -> Bool {
        guard let point, let grip else { return false }
        return hypot(grip.center.x - point.x, grip.center.y - point.y) <= grip.radius
    }

    private func setOverGrip(_ on: Bool) {
        guard on != overGrip else { return }
        overGrip = on
        call("__treeGrip", on)
        debugLog("별 \(on ? "위" : "밖") \(grip.map { "\($0.center) r\($0.radius)" } ?? "-") 비율 \(gripRatio)")
    }

    private func checkPointer() {
        guard settings["hidden"] as? Bool != true, drag == nil, resize == nil else { return }
        let point = mouseInWindow()
        let key = hit(at: point)
        overBody = point.map { at in body.contains { $0.contains(at) } } ?? false
        setHovered(key)
        setOverGrip(key == nil && onGrip(point))
        // 방울·별·몸통 위에 있을 때만 창이 마우스를 받는다. 그 밖에서는 전부 밑의 앱으로 통과한다.
        window.ignoresMouseEvents = key == nil && !overBody && !overGrip
    }

    private func setHovered(_ key: String?) {
        guard key != hovered else { return }
        hovered = key
        call("__treeHover", key ?? NSNull())
    }

    /// 방울을 눌렀으면 그 창에 일을 시키고, 별을 눌렀으면 크기를, 몸통을 눌렀으면 자리를 끌기 시작한다.
    private func pressed() {
        let point = mouseInWindow()
        guard let key = hit(at: point) ?? hovered else {
            let mouse = NSEvent.mouseLocation, frame = window.frame
            if onGrip(point), let grip {
                resize = (frame.maxY - grip.center.y - mouse.y, NSPoint(x: frame.midX, y: frame.minY))
            } else {
                drag = (mouse, frame.origin)
            }
            return
        }
        let parts = key.split(separator: ":")
        guard parts.count == 2, let id = UInt32(parts[0]) else { return }
        watcher.act(id: CGWindowID(id), kind: String(parts[1])) { [weak self] result in
            self?.call("__treePressed", key, result)
            if result == "denied" { self?.askForAccess() }
        }
    }

    private func dragged() {
        let mouse = NSEvent.mouseLocation
        if let resize {
            // 밑동은 그대로 있고 별이 마우스의 높이를 따라온다.
            let tall = (mouse.y + resize.offset - resize.base.y) / gripRatio
            let scale = min(max(tall / boardSize.height, scaleRange.lowerBound), scaleRange.upperBound)
            liveScale = scale
            let width = boardSize.width * scale, height = boardSize.height * scale
            window.setFrame(NSRect(x: resize.base.x - width / 2, y: resize.base.y, width: width, height: height), display: true)
            return
        }
        guard let drag else { return }
        window.setFrameOrigin(NSPoint(x: drag.origin.x + mouse.x - drag.mouse.x, y: drag.origin.y + mouse.y - drag.mouse.y))
    }

    /// 내려놓은 자리를 기억한다. 화면 밖에 걸쳤으면 안으로 밀어 넣는다.
    private func released() {
        if resize != nil {
            resize = nil
            let frame = Self.keptOnScreen(window.frame)
            // 줄이고 키운 자리에 그대로 서 있게, 밑동의 자리를 기억한다.
            UserDefaults.standard.set([Double(frame.midX), Double(frame.minY)], forKey: anchorKey)
            let scale = (Double(liveScale ?? 1) * 100).rounded() / 100
            call("__treeSet", "scale", scale)
            call("__treeMoved")
            debugLog("크기 \(scale)")
            return
        }
        guard let began = drag else { return }
        drag = nil
        guard window.frame.origin != began.origin else { return } // 누르기만 하고 안 끌었다
        let frame = Self.keptOnScreen(window.frame)
        UserDefaults.standard.set([Double(frame.midX), Double(frame.minY)], forKey: anchorKey)
        place()
        call("__treeMoved")
        debugLog("옮김 \(frame.origin)")
    }

    // MARK: 권한

    /// 처음에는 시스템이 묻는 창을 띄운다. 그 창은 한 번만 뜨므로, 그다음부터는 설정 화면을 연다.
    private func askForAccess() {
        if !UserDefaults.standard.bool(forKey: promptedKey) {
            UserDefaults.standard.set(true, forKey: promptedKey)
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            return
        }
        guard Date().timeIntervalSince(lastSettingsOpen) > 20 else { return } // 누를 때마다 설정이 튀어나오지 않게
        openAccessSettings()
    }

    @objc private func openAccessSettings() {
        lastSettingsOpen = Date()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: 메뉴바

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let path = Bundle.main.path(forResource: "tray", ofType: "png"),
           let image = NSImage(contentsOfFile: path) {
            image.isTemplate = true
            image.size = NSSize(width: 22, height: 22)
            statusItem.button?.image = image
        } else {
            statusItem.button?.title = "🎄"
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
    }

    /// 메뉴는 **열 때** 짓는다.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector? = nil, checked: Bool = false,
                 to target: NSMenu? = nil, value: Any? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = action != nil
            item.state = checked ? .on : .off
            item.representedObject = value
            (target ?? menu).addItem(item)
        }
        func flag(_ key: String) -> Bool { settings[key] as? Bool ?? false }
        func choices(_ title: String, key: String, fallback: String, _ options: [(String, String)]) {
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let sub = NSMenu()
            sub.autoenablesItems = false
            let now = settings[key] as? String ?? fallback
            for (label, value) in options {
                add(label, #selector(choose(_:)), checked: now == value, to: sub, value: [key, value])
            }
            parent.submenu = sub
            menu.addItem(parent)
        }

        add("창 \(windowCount)개의 방울이 달려 있습니다")
        add("빨강 닫기 · 노랑 접기 · 초록 키우기")
        add("트리를 끌면 옮겨지고, 별을 끌면 크기가 바뀝니다")
        if !AXIsProcessTrusted() {
            menu.addItem(.separator())
            add("⚠️ 손쉬운 사용 권한 켜기…", #selector(openAccessSettings))
            add("권한이 있어야 방울이 창을 움직입니다")
        }
        // 새 버전이 있을 때만 낸다. 없으면 메뉴에 아무 흔적도 없다.
        if let updateVersion {
            menu.addItem(.separator())
            add(updateNote ?? "새 버전 \(updateVersion) 설치", updating ? nil : #selector(installUpdate))
        }
        menu.addItem(.separator())
        add("숨기기", #selector(toggle(_:)), checked: flag("hidden"), value: "hidden")
        add("꼬마전구 반짝임", #selector(toggle(_:)), checked: flag("twinkle"), value: "twinkle")
        choices("자리 (끌어서도 옮깁니다)", key: "spot", fallback: "right", [("왼쪽 구석", "left"), ("오른쪽 구석", "right")])
        let sizes = NSMenuItem(title: "크기 (별을 끌어서도 바꿉니다)", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        sizeMenu.autoenablesItems = false
        for (label, value) in scalePresets {
            add(label, #selector(choose(_:)), checked: abs(Double(currentScale) - value) < 0.02, to: sizeMenu, value: ["scale", value])
        }
        sizes.submenu = sizeMenu
        menu.addItem(sizes)
        menu.addItem(.separator())
        add("로그인할 때 켜기", #selector(toggleLoginItem), checked: SMAppService.mainApp.status == .enabled)
        add("바탕화면 트리 제거…", #selector(uninstall))
        menu.addItem(.separator())
        add("버전 \(currentVersion)")
        menu.addItem(NSMenuItem(title: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// 설정은 렌더러가 쥐고 있다. 셸은 「이걸 이렇게 바꿔 달라」고만 한다.
    @objc private func toggle(_ item: NSMenuItem) {
        guard let key = item.representedObject as? String else { return }
        call("__treeSet", key, !(settings[key] as? Bool ?? false))
    }

    @objc private func choose(_ item: NSMenuItem) {
        guard let pair = item.representedObject as? [Any], pair.count == 2, let key = pair[0] as? String else { return }
        if key == "spot" { UserDefaults.standard.removeObject(forKey: anchorKey) } // 구석을 고르면 끌어다 놓은 자리는 잊는다
        call("__treeSet", key, pair[1])
        if key == "spot" { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.place() } } // 같은 구석을 또 골라도 돌아가게
    }

    /// **기본은 꺼 둔다** — 묻지 않고 로그인 항목에 들어가는 앱은 미움받는다.
    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            debugLog("로그인 항목 실패 \(error)")
        }
    }

    // MARK: 제거
    //
    // 앱을 휴지통에 끌어다 넣기만 하면 **남는 것이 셋** 있다 — 설정, 로그인 항목, 손쉬운 사용 권한.
    // 그래서 메뉴에서 한 번에 치운다.

    @objc private func uninstall() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "바탕화면 트리를 제거할까요?"
        alert.informativeText = "앱을 휴지통으로 옮기고, 설정과 로그인 항목, 손쉬운 사용 권한을 함께 지웁니다."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "제거")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let id = Bundle.main.bundleIdentifier ?? "dev.joowonkoh.desktop-tree"
        let home = FileManager.default.homeDirectoryForCurrentUser
        let leftovers = ["Library/WebKit/\(id)", "Library/Caches/\(id)", "Library/HTTPStorages/\(id)",
                         "Library/Saved Application State/\(id).savedState"].map { home.appendingPathComponent($0) }
        try? SMAppService.mainApp.unregister()
        UserDefaults.standard.removePersistentDomain(forName: id)
        UserDefaults.standard.synchronize()
        for url in leftovers { try? FileManager.default.removeItem(at: url) }
        run("/usr/bin/tccutil", ["reset", "Accessibility", id])
        // 지우지 않고 휴지통으로 — 마음이 바뀌면 꺼내면 된다.
        try? FileManager.default.trashItem(at: Bundle.main.bundleURL, resultingItemURL: nil)
        NSApp.terminate(nil)
    }

    // MARK: 업데이트
    //
    // **두 단계다.** 1단계는 「새 버전이 있다」고 메뉴에 알리는 것뿐이고, 2단계는 눌렀을 때 받아서
    // 갈아 끼우는 것이다. 손쉬운 사용 권한은 서명(팀 + 번들 ID)에 묶여 있어서, 같은 Developer ID 로
    // 서명한 새 버전은 권한을 다시 묻지 않는다.

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    private func scheduleUpdateChecks() {
        Timer.scheduledTimer(withTimeInterval: firstUpdateCheckDelay, repeats: false) { [weak self] _ in
            self?.checkForUpdate()
        }
        Timer.scheduledTimer(withTimeInterval: updateCheckInterval, repeats: true) { [weak self] _ in
            self?.checkForUpdate()
        }
    }

    /// 하루 한 번 물어본다. 실패는 조용히 삼킨다.
    private func checkForUpdate() {
        guard var request = URL(string: releaseAPI).map({ URLRequest(url: $0) }) else { return }
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String
            else { return }
            let assets = json["assets"] as? [[String: Any]] ?? []
            let zip = assets.first { ($0["name"] as? String)?.hasSuffix(macAssetSuffix) == true }
            let url = (zip?["browser_download_url"] as? String).flatMap(URL.init(string:))

            DispatchQueue.main.async {
                debugLog("릴리스 \(tag) · 지금 \(self.currentVersion)")
                guard isNewerVersion(tag, than: self.currentVersion) else { return }
                self.updateVersion = tag
                self.updateAsset = url
            }
        }.resume()
    }

    /// 받아서 갈아 끼운다. 어느 한 걸음이라도 어긋나면 **손대지 않고** 받는 곳을 연다.
    @objc private func installUpdate() {
        guard !updating else { return }
        guard let asset = updateAsset else { return openReleasePage() }
        updating = true
        updateNote = "내려받는 중…"

        URLSession.shared.downloadTask(with: asset) { [weak self] location, _, error in
            guard let self else { return }
            // 임시 파일은 이 블록이 끝나면 사라진다. 옆에 옮겨 두고 푼다.
            let work = FileManager.default.temporaryDirectory
                .appendingPathComponent("desktop-tree-update-\(UUID().uuidString)")
            let zip = work.appendingPathComponent("app.zip")
            guard let location, error == nil,
                  (try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)) != nil,
                  (try? FileManager.default.moveItem(at: location, to: zip)) != nil
            else {
                DispatchQueue.main.async { self.updateFailed() }
                return
            }
            DispatchQueue.main.async { self.swapIn(zip: zip, work: work) }
        }.resume()
    }

    private func swapIn(zip: URL, work: URL) {
        updateNote = "설치하는 중…"
        let unpacked = work.appendingPathComponent("unpacked")
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path]) == 0,
              let newApp = (try? FileManager.default.contentsOfDirectory(at: unpacked,
                                                                        includingPropertiesForKeys: nil))?
                  .first(where: { $0.pathExtension == "app" })
        else { return updateFailed() }

        // **받은 것이 애플이 검증한 우리 앱인지 본다.** 여기서 걸리면 갈아 끼우지 않는다 —
        // 남의 창을 닫을 권한을 가진 앱 자리에 남의 것을 넣는 일은 절대 없어야 한다.
        guard run("/usr/sbin/spctl", ["--assess", "--type", "execute", newApp.path]) == 0,
              let id = Bundle(url: newApp)?.bundleIdentifier, id == Bundle.main.bundleIdentifier
        else {
            debugLog("업데이트 검증 실패")
            return updateFailed()
        }

        let target = Bundle.main.bundleURL
        do {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: newApp)
        } catch {
            // 대개 권한 문제다(/Applications 밖이거나 다른 사용자 소유).
            debugLog("바꿔 끼우기 실패 \(error)")
            return updateFailed()
        }

        // 새 것을 띄우고 지금 것은 물러난다. 설정은 UserDefaults 에 있어서 그대로다.
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: target, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private func updateFailed() {
        updating = false
        updateNote = "직접 받기"
        openReleasePage()
    }

    private func openReleasePage() {
        if let url = URL(string: releasePage) { NSWorkspace.shared.open(url) }
    }

    // MARK: 디버그

    /// notifyutil -p tree.eval — TREE_EVAL 이 가리키는 파일의 JS 를 렌더러에서 돌리고 결과를 적는다.
    private func registerDebugTriggers() {
        var evalToken: Int32 = 0
        notify_register_dispatch("tree.eval", &evalToken, .main) { [weak self] _ in
            guard let path = ProcessInfo.processInfo.environment["TREE_EVAL"],
                  let code = try? String(contentsOfFile: path, encoding: .utf8) else { return }
            self?.webView.evaluateJavaScript(code) { result, error in
                debugLog("eval → \(result.map { "\($0)" } ?? "-") \(error.map { "\($0)" } ?? "")")
            }
        }
    }

    // MARK: 렌더러에서 오는 것

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        switch body["type"] as? String {
        case "log":
            if let text = body["text"] as? String {
                FileHandle.standardError.write("[web] \(text)\n".data(using: .utf8)!)
            }
        case "state":
            if let json = body["json"] as? String { UserDefaults.standard.set(json, forKey: stateKey) }
        case "settings":
            settings = body["settings"] as? [String: Any] ?? [:]
            if resize == nil { liveScale = nil } // 끌어서 정한 크기가 설정으로 돌아왔다
            place()
            debugLog("설정 \(settings)")
        case "body":
            let list = body["list"] as? [[String: Any]] ?? []
            self.body = list.compactMap { item in
                guard let x = item["x"] as? Double, let y = item["y"] as? Double,
                      let w = item["w"] as? Double, let h = item["h"] as? Double else { return nil }
                return CGRect(x: x, y: y, width: w, height: h)
            }
        case "grip":
            func number(_ key: String) -> CGFloat { CGFloat((body[key] as? NSNumber)?.doubleValue ?? 0) }
            grip = (CGPoint(x: number("x"), y: number("y")), number("r"))
            let tall = window.frame.height
            if resize == nil, tall > 0, number("y") > 0 { gripRatio = (tall - number("y")) / tall }
        case "ready":
            watcher.resend()
        case "hits":
            let list = body["list"] as? [[String: Any]] ?? []
            hits = list.compactMap { item in
                guard let key = item["key"] as? String, let x = item["x"] as? Double,
                      let y = item["y"] as? Double, let r = item["r"] as? Double else { return nil }
                return (key, CGPoint(x: x, y: y), CGFloat(r))
            }
            debugLog("누를 자리 \(hits.count)개")
        default: break
        }
    }

    /// NSScreen.main 은 「키 윈도우가 있는 화면」이라 포커스를 안 갖는 이 앱에서는 엉뚱한
    /// 모니터를 집는다 — 전역 좌표 원점인 쪽이 주 화면이다.
    static var primaryScreen: NSScreen {
        NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first ?? NSScreen.main!
    }
}

// MARK: - 시작

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory) // Dock 아이콘도 메뉴도 없다. 조작 창구는 메뉴바와 방울뿐
app.run()
