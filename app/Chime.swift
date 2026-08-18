// チャイム.app — 決めた予定どおりに学校のチャイムを鳴らす常駐アプリ。
//
// 予定の計算は隣の chime.py に任せている（ターミナルの表示とアプリが食い違わないように）。
// このファイルは UI と、時刻がきたら音を鳴らす部分だけを持つ。
//
// ビルド: ./build_app.sh

import AppKit
import Combine
import ServiceManagement
import SwiftUI

// MARK: - モデル

struct RoutineEvent: Codable, Identifiable, Hashable {
    var id: String { time + label }
    var time: String
    var label: String
    var sound: String?
    var task: String?
}

struct Agenda: Decodable {
    struct DayType: Decodable, Hashable {
        let key: String
        let title: String
    }
    struct Config: Decodable {
        var enabled: Bool
        var volume: Double
        var notify: Bool
        var pre_chime_minutes: Int
        var grace_seconds: Int
        var date_overrides: [String: String]
        var disabled_dates: [String]
        var mute_times: [String]
    }
    struct Event: Decodable {
        let time: String
        let at: String
        let label: String
        let sound: String
    }
    struct Day: Decodable {
        let date: String
        let weekday: String
        let calendar_label: String
        let day_type: String?
        let title: String?
        let note: String?
        let events: [Event]
    }
    let root: String
    let day_types: [DayType]
    let config: Config
    let days: [Day]
}

/// カレンダー画面用。calendar-get の出力。
struct CalendarFile: Decodable {
    struct Period: Decodable, Equatable {
        var start: String
        var end: String
    }
    struct Day: Decodable, Identifiable {
        var id: String { date }
        let date: String
        let weekday: String
        let label: String
        let assigned: String?
        let day_type: String?
        let title: String?
        let count: Int
        let disabled: Bool
    }
    let study_period: Period
    let day_types: [Agenda.DayType]
    let days: [Day]
}

struct RoutinesFile: Decodable {
    struct Routine: Decodable {
        let title: String
        let note: String?
        let events: [RoutineEvent]
    }
    let routines: [String: Routine]
}

/// 実際に鳴らす1回分。
struct Ring {
    let at: Date
    let time: String
    let label: String
    let sound: String
}

// MARK: - chime.py の呼び出し

enum PythonError: LocalizedError {
    case notFound
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "チャイムのフォルダが見つからない。\n"
                 + "チャイム.app は「チャイム」フォルダの中に置いたままにしておく。"
        case .failed(let message):
            return message
        }
    }
}

enum Runner {
    /// chime.py があるフォルダ。アプリと同じ階層 → デスクトップの順に探す。
    static let root: URL? = {
        let fm = FileManager.default
        var candidates = [Bundle.main.bundleURL.deletingLastPathComponent()]
        candidates.append(fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/チャイム"))
        return candidates.first { fm.fileExists(atPath: $0.appendingPathComponent("chime.py").path) }
    }()

    /// data/calendar.json がまだ無い＝はじめて使う状態。
    static var needsSetup: Bool {
        guard let root else { return false }
        return !FileManager.default.fileExists(
            atPath: root.appendingPathComponent("data/calendar.json").path)
    }

    @discardableResult
    static func run(_ args: [String]) throws -> Data {
        guard let root else { throw PythonError.notFound }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        task.arguments = ["chime.py"] + args
        task.currentDirectoryURL = root
        let out = Pipe(), err = Pipe()
        task.standardOutput = out
        task.standardError = err
        try task.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            let msg = String(data: errData, encoding: .utf8) ?? ""
            throw PythonError.failed(msg.isEmpty ? "chime.py が失敗した" : msg)
        }
        return data
    }

    static func json<T: Decodable>(_ type: T.Type, _ args: [String]) throws -> T {
        try JSONDecoder().decode(T.self, from: run(args))
    }
}

/// macOS の通知を出す。出せたら true。
@discardableResult
func postNotification(title: String, body: String) -> Bool {
    func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    task.arguments = ["-e", "display notification \(quote(body)) with title \(quote(title))"]
    task.standardError = Pipe()
    do {
        try task.run()
        task.waitUntilExit()
        return task.terminationStatus == 0
    } catch {
        return false
    }
}

// MARK: - エンジン

@MainActor
final class Engine: ObservableObject {
    @Published private(set) var agenda: Agenda?
    @Published private(set) var errorText: String?
    @Published private(set) var needsSetup = Runner.needsSetup
    @Published private(set) var lastRung: (label: String, at: Date)?

    private var rings: [Ring] = []
    private var anchor = Date().addingTimeInterval(-120)
    private var sound: NSSound?
    private var timer: Timer?
    private var loadedOn = ""
    private var browseCache: [String: Agenda.Day] = [:]

    var config: Agenda.Config? { agenda?.config }
    var today: Agenda.Day? { agenda?.days.first }

    /// まだ鳴っていない、いちばん近いチャイム。
    var next: Ring? {
        let now = Date()
        return rings.first { $0.at > now }
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// 画面で日付を送って見るための取得。今日の前後は読み込み済みのものを使う。
    func day(for date: Date) -> Agenda.Day? {
        let key = Self.dayFormatter.string(from: date)
        if let found = agenda?.days.first(where: { $0.date == key }) { return found }
        if let cached = browseCache[key] { return cached }
        guard let fetched = try? Runner.json(Agenda.self, ["agenda", "--date", key, "--days", "1"]),
              let day = fetched.days.first else { return nil }
        browseCache[key] = day
        return day
    }

    init() {
        if let saved = UserDefaults.standard.object(forKey: "anchor") as? Date,
           saved < Date(), saved > Date().addingTimeInterval(-86400) {
            anchor = saved
        }
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    // MARK: 読み込み

    func reload() {
        browseCache.removeAll()
        needsSetup = Runner.needsSetup
        if needsSetup {
            agenda = nil
            errorText = nil
            rings = []
            objectWillChange.send()
            return
        }
        do {
            let fetched = try Runner.json(Agenda.self, ["agenda", "--days", "3"])
            agenda = fetched
            errorText = nil
            loadedOn = Self.dayKey(Date())

            let parser = Self.stampFormatter
            rings = fetched.days.flatMap { day in
                day.events.compactMap { ev in
                    parser.date(from: ev.at).map {
                        Ring(at: $0, time: ev.time, label: ev.label, sound: ev.sound)
                    }
                }
            }.sorted { $0.at < $1.at }
        } catch {
            errorText = error.localizedDescription
            rings = []
        }
        objectWillChange.send()
    }

    private static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    // MARK: 時刻の監視

    private func tick() {
        let now = Date()
        if Self.dayKey(now) != loadedOn { reload() }

        let grace = TimeInterval(config?.grace_seconds ?? 120)
        for ring in rings where ring.at > anchor && ring.at <= now {
            if now.timeIntervalSince(ring.at) <= grace {
                fire(ring)
            }
            anchor = ring.at
            UserDefaults.standard.set(anchor, forKey: "anchor")
        }
        objectWillChange.send()
    }

    private func fire(_ ring: Ring) {
        guard config?.enabled ?? true else { return }
        play(ring.sound)
        lastRung = (ring.label, Date())
        if config?.notify ?? true {
            notify(title: "\(ring.time)  チャイム", body: ring.label)
        }
    }

    // MARK: 再生・通知

    func play(_ kind: String) {
        guard let root = Runner.root else { return }
        let name = ["chime": "chime.wav", "pre": "chime_pre.wav", "night": "chime_night.wav"][kind]
            ?? "chime.wav"
        let url = root.appendingPathComponent("sounds/\(name)")
        guard let s = NSSound(contentsOf: url, byReference: true) else { return }
        s.volume = Float(min(max(config?.volume ?? 1.0, 0), 1))
        sound?.stop()
        sound = s
        s.play()
    }

    func stopSound() {
        sound?.stop()
        sound = nil
    }

    private func notify(title: String, body: String) {
        DispatchQueue.global(qos: .utility).async {
            _ = postNotification(title: title, body: body)
        }
    }

    // MARK: 設定の書き換え

    /// 例: patch(["volume": 0.8])
    func patch(_ values: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: values),
              let text = String(data: data, encoding: .utf8) else { return }
        do {
            try Runner.run(["config-set", "--json", text])
            reload()
        } catch {
            errorText = error.localizedDescription
        }
    }

    func saveRoutine(type: String, events: [RoutineEvent]) -> String? {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(events),
              let text = String(data: data, encoding: .utf8) else { return "書き出せなかった" }
        do {
            let result = try Runner.run(["routine-set", "--type", type, "--json", text])
            let obj = try JSONSerialization.jsonObject(with: result) as? [String: Any]
            if let ok = obj?["ok"] as? Bool, !ok {
                return obj?["error"] as? String ?? "保存に失敗した"
            }
            reload()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// はじめて使うときに data/ を作る。成功したら nil、失敗したら理由を返す。
    func setUp(start: Date, end: Date) -> String? {
        let f = Self.dayFormatter
        do {
            try Runner.run(["init", "--start", f.string(from: start),
                            "--end", f.string(from: end)])
            reload()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// カレンダー画面用。指定日から days 日ぶんの割り当てを読む。
    func calendar(from: Date, days: Int) -> CalendarFile? {
        try? Runner.json(CalendarFile.self,
                         ["calendar-get", "--start", Self.dayFormatter.string(from: from),
                          "--days", String(days)])
    }

    /// 日付への日課の割り当てを書き換える。type が nil なら割り当てを消す。
    @discardableResult
    func assign(date: String, type: String?) -> String? {
        setCalendar(["types": [date: type ?? ""]])
    }

    /// 学習期間を書き換える。
    @discardableResult
    func setPeriod(start: Date, end: Date) -> String? {
        let f = Self.dayFormatter
        return setCalendar(["study_period": ["start": f.string(from: start),
                                             "end": f.string(from: end)]])
    }

    private func setCalendar(_ patch: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: patch),
              let text = String(data: data, encoding: .utf8) else { return "書き出せなかった" }
        do {
            let out = try Runner.run(["calendar-set", "--json", text])
            if let obj = try? JSONSerialization.jsonObject(with: out) as? [String: Any],
               obj["ok"] as? Bool == false {
                return obj["error"] as? String ?? "保存できなかった"
            }
            reload()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func loadRoutines() -> RoutinesFile? {
        try? Runner.json(RoutinesFile.self, ["routines-get"])
    }
}

// MARK: - メインウインドウ

/// はじめて使うときの画面。data/ がまだ無いときに出る。
struct SetupView: View {
    @ObservedObject var engine: Engine
    @State private var start = Date()
    @State private var end = SetupView.defaultEnd()
    @State private var error: String?
    @State private var working = false

    /// 学習期間の終わりの初期値。次にくる 3月31日。
    static func defaultEnd() -> Date {
        let cal = Foundation.Calendar.current
        let now = Date()
        var c = cal.dateComponents([.year], from: now)
        c.month = 3; c.day = 31
        let thisYear = cal.date(from: c) ?? now
        return thisYear > now ? thisYear
            : cal.date(byAdding: .year, value: 1, to: thisYear) ?? now
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 0)
            VStack(spacing: 10) {
                Image(systemName: "bell.fill")
                    .font(.system(size: 40)).foregroundStyle(Color.accentColor)
                Text("チャイムへようこそ").font(.title).fontWeight(.semibold)
                Text("決めた時刻に学校のチャイムを鳴らします。\nまず、いつからいつまで使うかを決めます。")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 4)

            Form {
                Section("使う期間") {
                    DatePicker("始まり", selection: $start, displayedComponents: .date)
                    DatePicker("終わり", selection: $end, in: start..., displayedComponents: .date)
                }
                Section {
                    Text("平日・土曜・日曜・長期休暇・考査日・祝日などの日課を、"
                       + "よくある時間割で用意します。時刻も内容も、あとから設定画面で自由に変えられます。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(maxHeight: 230)
            .scrollDisabled(true)

            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            Button(working ? "作成中…" : "はじめる") { create() }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(working)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 28)
        .frame(minWidth: 560, minHeight: 540)
    }

    private func create() {
        working = true
        error = engine.setUp(start: start, end: end)
        working = false
    }
}

struct MainView: View {
    @ObservedObject var engine: Engine
    let openSettings: () -> Void
    @State private var shown = Date()
    @State private var now = Date()

    private let ticker = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    private static let title: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy年M月d日"
        return f
    }()

    private var isToday: Bool {
        Calendar.current.isDateInToday(shown)
    }

    private var day: Agenda.Day? { engine.day(for: shown) }

    var body: some View {
        Group {
            if engine.needsSetup {
                SetupView(engine: engine)
            } else {
                VStack(spacing: 0) {
                    header
                    Divider()
                    if let error = engine.errorText {
                        errorBox(error)
                    } else {
                        schedule
                    }
                    Divider()
                    footer
                }
                .frame(minWidth: 560, minHeight: 540)
            }
        }
        .onReceive(ticker) { now = $0 }
    }

    // MARK: 上部

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button { move(-1) } label: { Image(systemName: "chevron.left") }
                Button { move(1) } label: { Image(systemName: "chevron.right") }
                Text("\(Self.title.string(from: shown))（\(day?.weekday ?? "")）")
                    .font(.title2).fontWeight(.semibold)
                if !isToday {
                    Button("今日") { shown = Date() }
                }
                Spacer()
                if let label = day?.calendar_label, !label.isEmpty {
                    Text(label)
                        .font(.callout)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                }
            }
            Text(day?.title ?? "予定なし（この日は鳴らない）")
                .font(.headline).foregroundStyle(.secondary)
            if let note = day?.note {
                Text(note).font(.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
    }

    private func move(_ days: Int) {
        shown = Calendar.current.date(byAdding: .day, value: days, to: shown) ?? shown
    }

    // MARK: 予定表

    private var schedule: some View {
        Group {
            if let events = day?.events, !events.isEmpty {
                List(events.indices, id: \.self) { index in
                    row(events[index])
                }
                .listStyle(.inset)
            } else {
                VStack {
                    Spacer()
                    Text("この日にチャイムはない").foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }

    private func row(_ event: Agenda.Event) -> some View {
        let at = Engine.stampFormatter.date(from: event.at) ?? now
        let isNext = isToday && engine.next?.at == at
        let done = isToday && at <= now

        let markColor: Color = isNext ? .accentColor
                                      : (done ? .secondary : Color.secondary.opacity(0.4))
        return HStack(spacing: 12) {
            Image(systemName: isNext ? "arrowtriangle.right.fill"
                                     : (done ? "checkmark.circle.fill" : "circle"))
                .foregroundStyle(markColor)
                .frame(width: 16)
            Text(event.time)
                .font(.system(.title3, design: .monospaced))
                .fontWeight(isNext ? .bold : .regular)
                .foregroundStyle(done && !isNext ? .secondary : .primary)
            Text(event.label)
                .fontWeight(isNext ? .semibold : .regular)
                .foregroundStyle(done && !isNext ? .secondary : .primary)
            Spacer()
            if event.sound == "night" {
                Text("消灯").font(.caption).foregroundStyle(.secondary)
            } else if event.sound == "pre" {
                Text("予鈴").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private func errorBox(_ text: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle").font(.largeTitle)
            Text(text).multilineTextAlignment(.center).padding(.horizontal, 40)
            Button("もう一度読み込む") { engine.reload() }
            Spacer()
        }
    }

    // MARK: 下部

    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if !(engine.config?.enabled ?? true) {
                    Label("一時停止中", systemImage: "bell.slash")
                        .foregroundStyle(.orange)
                } else if let next = engine.next {
                    Text("次のチャイム  \(next.time)  \(next.label)")
                        .fontWeight(.medium).lineLimit(1)
                    Text(remaining(until: next.at)).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("この先の予定なし").foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(engine.config?.enabled ?? true ? "一時停止" : "再開") {
                engine.patch(["enabled": !(engine.config?.enabled ?? true)])
                engine.stopSound()
            }
            Button("鳴らしてみる") { engine.play("chime") }
            Button("設定…", action: openSettings)
                .keyboardShortcut(",", modifiers: .command)
        }
        .padding(16)
    }

    private func remaining(until date: Date) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        if seconds < 60 { return "まもなく" }
        let hours = seconds / 3600, minutes = (seconds % 3600) / 60
        let today = Calendar.current.isDateInToday(date) ? "" : "明日 "
        return hours > 0 ? "\(today)あと \(hours)時間\(minutes)分" : "\(today)あと \(minutes)分"
    }
}

// MARK: - 設定画面

struct SettingsView: View {
    @ObservedObject var engine: Engine
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            GeneralTab(engine: engine)
                .tabItem { Label("基本", systemImage: "bell") }.tag(0)
            CalendarTab(engine: engine)
                .tabItem { Label("カレンダー", systemImage: "calendar") }.tag(1)
            RoutineTab(engine: engine)
                .tabItem { Label("日課の編集", systemImage: "list.bullet") }.tag(2)
            DatesTab(engine: engine)
                .tabItem { Label("そのほか", systemImage: "slider.horizontal.3") }.tag(3)
        }
        .padding(16)
        .frame(width: 680, height: 640)
    }
}

struct GeneralTab: View {
    @ObservedObject var engine: Engine
    @State private var loginItem = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    private var cfg: Agenda.Config? { engine.config }

    var body: some View {
        Form {
            Section {
                Toggle("チャイムを鳴らす", isOn: Binding(
                    get: { cfg?.enabled ?? true },
                    set: { engine.patch(["enabled": $0]) }))

                HStack {
                    Text("音量")
                    Slider(value: Binding(
                        get: { cfg?.volume ?? 1.0 },
                        set: { engine.patch(["volume": (($0 * 20).rounded()) / 20]) }),
                           in: 0...1)
                    Text(String(format: "%.0f%%", (cfg?.volume ?? 1) * 100))
                        .monospacedDigit().frame(width: 44, alignment: .trailing)
                    Button("試聴") { engine.play("chime") }
                }

                Toggle("鳴らすときに通知も出す", isOn: Binding(
                    get: { cfg?.notify ?? true },
                    set: { engine.patch(["notify": $0]) }))

                Picker("予鈴", selection: Binding(
                    get: { cfg?.pre_chime_minutes ?? 0 },
                    set: { engine.patch(["pre_chime_minutes": $0]) })) {
                    Text("鳴らさない").tag(0)
                    Text("3分前").tag(3)
                    Text("5分前").tag(5)
                    Text("10分前").tag(10)
                }
            }

            Section {
                Toggle("Mac のログイン時に自動で起動する", isOn: $loginItem)
                    .onChange(of: loginItem) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = "登録できなかった（\(error.localizedDescription)）。"
                                + "システム設定 > 一般 > ログイン項目 で チャイム.app を手で追加する。"
                            loginItem = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }

            Section {
                LabeledContent("フォルダ") {
                    HStack {
                        Text(Runner.root?.path ?? "見つからない")
                            .font(.caption).lineLimit(1).truncationMode(.head)
                        Button("開く") {
                            if let root = Runner.root { NSWorkspace.shared.open(root) }
                        }
                    }
                }
                if let error = engine.errorText {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// 日付にどの日課をわりあてるかを、月のカレンダーで決める画面。
struct CalendarTab: View {
    @ObservedObject var engine: Engine
    @State private var month = Date()
    @State private var file: CalendarFile?
    @State private var selection: Set<String> = []
    @State private var lastPicked: String?
    @State private var message: String?
    @State private var periodStart = Date()
    @State private var periodEnd = Date()
    @State private var periodLoaded = false

    private let cal = Foundation.Calendar.current

    private static let monthTitle: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy年M月"
        return f
    }()

    private static let key: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// 日課タイプごとの色。凡例とマス目で同じ色を使う。
    private static let palette: [Color] = [.blue, .green, .orange, .purple, .pink,
                                           .teal, .indigo, .brown, .red]

    private func color(for type: String?) -> Color? {
        guard let type, let types = file?.day_types,
              let i = types.firstIndex(where: { $0.key == type }) else { return nil }
        return Self.palette[i % Self.palette.count]
    }

    /// グリッドの左上（その月の1日を含む週の日曜）。
    private var gridStart: Date {
        let first = cal.date(from: cal.dateComponents([.year, .month], from: month)) ?? month
        let offset = cal.component(.weekday, from: first) - 1
        return cal.date(byAdding: .day, value: -offset, to: first) ?? first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            period
            Divider()
            monthHeader
            weekdayRow
            grid
            Divider()
            assignBar
        }
        .onAppear(perform: load)
    }

    // MARK: 学習期間

    private var period: some View {
        HStack(spacing: 8) {
            Text("使う期間").fontWeight(.medium)
            DatePicker("", selection: $periodStart, displayedComponents: .date)
                .labelsHidden()
            Text("〜").foregroundStyle(.secondary)
            DatePicker("", selection: $periodEnd, in: periodStart..., displayedComponents: .date)
                .labelsHidden()
            Button("変更") {
                message = engine.setPeriod(start: periodStart, end: periodEnd) ?? "期間を変えた"
                load()
            }
            Spacer()
        }
    }

    // MARK: 月の移動

    private var monthHeader: some View {
        HStack(spacing: 10) {
            Button { move(-1) } label: { Image(systemName: "chevron.left") }
            Text(Self.monthTitle.string(from: month)).font(.title3).fontWeight(.semibold)
            Button { move(1) } label: { Image(systemName: "chevron.right") }
            Button("今月") { month = Date(); load() }
            Spacer()
            Text("クリックで選ぶ／⇧クリックで範囲／⌘クリックで追加")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func move(_ months: Int) {
        month = cal.date(byAdding: .month, value: months, to: month) ?? month
        load()
    }

    private var weekdayRow: some View {
        HStack(spacing: 4) {
            ForEach(Array("日月火水木金土".map(String.init)), id: \.self) { w in
                Text(w).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: マス目

    private var grid: some View {
        let days = file?.days ?? []
        return VStack(spacing: 4) {
            ForEach(0..<6, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(0..<7, id: \.self) { col in
                        let i = row * 7 + col
                        if i < days.count { cell(days[i]) } else { Color.clear }
                    }
                }
            }
        }
    }

    private func cell(_ day: CalendarFile.Day) -> some View {
        let inMonth = Self.key.date(from: day.date).map {
            cal.isDate($0, equalTo: month, toGranularity: .month)
        } ?? false
        let picked = selection.contains(day.date)
        let tint = color(for: day.day_type)
        let isToday = day.date == Self.key.string(from: Date())

        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Text(String(Int(day.date.suffix(2)) ?? 0))
                    .font(.callout).fontWeight(isToday ? .bold : .regular)
                    .monospacedDigit()
                if day.assigned != nil {
                    Circle().fill(tint ?? .secondary).frame(width: 5, height: 5)
                }
                Spacer(minLength: 0)
            }
            Text(day.disabled ? "鳴らさない" : (day.title ?? "—"))
                .font(.system(size: 9)).lineLimit(2)
                .foregroundStyle(day.disabled ? Color.secondary : (tint ?? .secondary))
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(4)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .topLeading)
        .background((tint ?? .gray).opacity(picked ? 0.35 : 0.10),
                    in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(picked ? Color.accentColor : (isToday ? Color.primary.opacity(0.5) : .clear),
                          lineWidth: picked ? 2 : 1))
        .opacity(inMonth ? 1 : 0.35)
        .contentShape(Rectangle())
        .onTapGesture { pick(day.date) }
    }

    /// ⇧で範囲、⌘で足し引き、ふつうのクリックは選び直し。
    private func pick(_ date: String) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift), let anchor = lastPicked,
           let all = file?.days.map(\.date),
           let a = all.firstIndex(of: anchor), let b = all.firstIndex(of: date) {
            selection = Set(all[min(a, b)...max(a, b)])
        } else if flags.contains(.command) {
            if selection.contains(date) { selection.remove(date) } else { selection.insert(date) }
            lastPicked = date
        } else {
            selection = [date]
            lastPicked = date
        }
    }

    // MARK: わりあて

    private var assignBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(selection.isEmpty ? "日付を選ぶと、下から日課をわりあてられる"
                                       : "\(selection.count)日を選択中 — わりあてる日課を選ぶ")
                    .foregroundStyle(selection.isEmpty ? .secondary : .primary)
                Spacer()
                if let message {
                    Text(message).font(.caption)
                        .foregroundStyle(message.hasSuffix("た") ? Color.secondary : Color.red)
                }
            }
            FlowRow {
                ForEach(file?.day_types ?? [], id: \.key) { type in
                    Button {
                        apply(type.key)
                    } label: {
                        HStack(spacing: 4) {
                            Circle().fill(color(for: type.key) ?? .gray)
                                .frame(width: 7, height: 7)
                            Text(type.title).lineLimit(1)
                        }
                    }
                    .disabled(selection.isEmpty)
                }
                Button("曜日どおりに戻す") { apply(nil) }
                    .disabled(selection.isEmpty)
            }
            Text("わりあてた日には点が付く。わりあてていない日は曜日どおり。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func apply(_ type: String?) {
        var failed: String?
        for date in selection.sorted() {
            if let error = engine.assign(date: date, type: type) { failed = error; break }
        }
        message = failed ?? (type == nil ? "曜日どおりに戻した" : "わりあてた")
        load()
    }

    private func load() {
        file = engine.calendar(from: gridStart, days: 42)
        if let period = file?.study_period, !periodLoaded {
            periodStart = Self.key.date(from: period.start) ?? Date()
            periodEnd = Self.key.date(from: period.end) ?? Date()
            periodLoaded = true
        }
    }
}

/// ボタンを折り返して並べる。日課タイプの数が増えても崩れないように。
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 500
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct RoutineTab: View {
    @ObservedObject var engine: Engine
    @State private var selected = ""
    @State private var events: [RoutineEvent] = []
    @State private var message: String?
    @State private var dirty = false

    private var dayTypes: [Agenda.DayType] { engine.agenda?.day_types ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("日課", selection: $selected) {
                ForEach(dayTypes, id: \.key) { Text($0.title).tag($0.key) }
            }
            .onChange(of: selected) { _, _ in load() }

            Text("チャイムを鳴らす時刻と、そのとき表示する内容。")
                .font(.caption).foregroundStyle(.secondary)

            List {
                ForEach($events) { $event in
                    HStack(spacing: 8) {
                        TextField("00:00", text: $event.time)
                            .frame(width: 60).monospacedDigit()
                            .onChange(of: event.time) { _, _ in dirty = true }
                        TextField("内容", text: $event.label)
                            .onChange(of: event.label) { _, _ in dirty = true }
                        Picker("", selection: Binding(
                            get: { event.sound ?? "chime" },
                            set: { event.sound = $0; dirty = true })) {
                            Text("通常").tag("chime")
                            Text("消灯").tag("night")
                            Text("予鈴音").tag("pre")
                        }
                        .labelsHidden().frame(width: 80)
                        Button {
                            events.removeAll { $0.id == event.id }
                            dirty = true
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            .frame(minHeight: 260)

            HStack {
                Button("行を追加") {
                    events.append(RoutineEvent(time: "12:00", label: "", sound: "chime"))
                    dirty = true
                }
                Spacer()
                if let message {
                    Text(message).font(.caption)
                        .foregroundStyle(message.hasPrefix("保存") ? Color.secondary : Color.red)
                }
                Button("元に戻す") { load() }.disabled(!dirty)
                Button("保存") { save() }.keyboardShortcut(.defaultAction).disabled(!dirty)
            }
        }
        .onAppear {
            if selected.isEmpty {
                selected = engine.today?.day_type ?? dayTypes.first?.key ?? ""
            }
            load()
        }
    }

    private func load() {
        guard !selected.isEmpty, let file = engine.loadRoutines() else { return }
        events = file.routines[selected]?.events ?? []
        dirty = false
        message = nil
    }

    private func save() {
        if let error = engine.saveRoutine(type: selected, events: events) {
            message = error
        } else {
            message = "保存した"
            dirty = false
            load()
        }
    }
}

struct DatesTab: View {
    @ObservedObject var engine: Engine
    @State private var newDate = Date()
    @State private var newType = ""
    @State private var newMute = ""

    private var cfg: Agenda.Config? { engine.config }
    private var dayTypes: [Agenda.DayType] { engine.agenda?.day_types ?? [] }

    private static let key: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var body: some View {
        Form {
            Section("この日は別の日課にする") {
                ForEach((cfg?.date_overrides ?? [:]).sorted(by: { $0.key < $1.key }), id: \.key) { date, type in
                    HStack {
                        Text(date).monospacedDigit()
                        Text(dayTypes.first { $0.key == type }?.title ?? type)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("削除") {
                            var m = cfg?.date_overrides ?? [:]
                            m.removeValue(forKey: date)
                            engine.patch(["date_overrides": m])
                        }
                    }
                }
                HStack {
                    DatePicker("", selection: $newDate, displayedComponents: .date).labelsHidden()
                    Picker("", selection: $newType) {
                        Text("選ぶ").tag("")
                        ForEach(dayTypes, id: \.key) { Text($0.title).tag($0.key) }
                    }.labelsHidden()
                    Button("追加") {
                        var m = cfg?.date_overrides ?? [:]
                        m[Self.key.string(from: newDate)] = newType
                        engine.patch(["date_overrides": m])
                        newType = ""
                    }.disabled(newType.isEmpty)
                }
                Text("「カレンダー」でまとめてわりあてるのが基本。ここは1日だけ例外にしたいときに使う。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("この日は鳴らさない") {
                ForEach(cfg?.disabled_dates.sorted() ?? [], id: \.self) { date in
                    HStack {
                        Text(date).monospacedDigit()
                        Spacer()
                        Button("削除") {
                            engine.patch(["disabled_dates":
                                (cfg?.disabled_dates ?? []).filter { $0 != date }])
                        }
                    }
                }
                Button("上で選んだ日付を追加") {
                    var list = cfg?.disabled_dates ?? []
                    let key = Self.key.string(from: newDate)
                    if !list.contains(key) { list.append(key) }
                    engine.patch(["disabled_dates": list])
                }
            }

            Section("この時刻は鳴らさない") {
                ForEach(cfg?.mute_times.sorted() ?? [], id: \.self) { time in
                    HStack {
                        Text(time).monospacedDigit()
                        Spacer()
                        Button("削除") {
                            engine.patch(["mute_times":
                                (cfg?.mute_times ?? []).filter { $0 != time }])
                        }
                    }
                }
                HStack {
                    TextField("08:35", text: $newMute).frame(width: 80)
                    Button("追加") {
                        var list = cfg?.mute_times ?? []
                        if !list.contains(newMute) { list.append(newMute) }
                        engine.patch(["mute_times": list])
                        newMute = ""
                    }.disabled(newMute.isEmpty)
                }
                Text("すべての日で、この時刻だけ鳴らさない。授業中の時刻を消したいときに使う。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - アプリ本体

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let engine = Engine()
    private var statusItem: NSStatusItem!
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var refresh: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildAppMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateTitle()

        refresh = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateTitle() }
        }
        RunLoop.main.add(refresh!, forMode: .common)

        showMainWindow()

        if Runner.root == nil {
            let alert = NSAlert()
            alert.messageText = "チャイムのフォルダが見つからない"
            alert.informativeText = "チャイム.app は chime.py と同じ「チャイム」フォルダの中に "
                                  + "置いたままにしておく。"
            alert.runModal()
        }
    }

    /// ウインドウを閉じてもチャイムは鳴り続ける。終了は ⌘Q。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showMainWindow()
        return true
    }

    // MARK: メインウインドウ

    @objc func showMainWindow() {
        if mainWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            window.title = "チャイム"
            window.contentView = NSHostingView(
                rootView: MainView(engine: engine, openSettings: { [weak self] in self?.openSettings() }))
            window.setFrameAutosaveName("main")
            window.center()
            window.isReleasedWhenClosed = false
            mainWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: 画面上部のメニュー

    private func buildAppMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "チャイム")
        appMenu.addItem(withTitle: "チャイムについて", action: #selector(about), keyEquivalent: "")
            .target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "設定…", action: #selector(openSettings), keyEquivalent: ",")
            .target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "チャイムを隠す",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "ほかを隠す",
                        action: #selector(NSApplication.hideOtherApplications(_:)),
                        keyEquivalent: "h").keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "チャイムを終了",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let chimeItem = NSMenuItem()
        let chimeMenu = NSMenu(title: "チャイム")
        chimeMenu.addItem(withTitle: "今すぐ鳴らしてみる",
                          action: #selector(testRing), keyEquivalent: "t").target = self
        chimeMenu.addItem(withTitle: "一時停止 / 再開",
                          action: #selector(togglePause), keyEquivalent: "p").target = self
        chimeMenu.addItem(.separator())
        chimeMenu.addItem(withTitle: "予定を読み直す",
                          action: #selector(reloadNow), keyEquivalent: "r").target = self
        chimeMenu.addItem(withTitle: "フォルダを開く",
                          action: #selector(openFolder), keyEquivalent: "").target = self
        chimeItem.submenu = chimeMenu
        main.addItem(chimeItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "ウインドウ")
        windowMenu.addItem(withTitle: "予定のウインドウ",
                           action: #selector(showMainWindow), keyEquivalent: "0").target = self
        windowMenu.addItem(withTitle: "しまう",
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "拡大/縮小",
                           action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: "ヘルプ")
        helpMenu.addItem(withTitle: "説明書（README）を開く",
                         action: #selector(openReadme), keyEquivalent: "?").target = self
        helpItem.submenu = helpMenu
        main.addItem(helpItem)
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = main
    }

    @objc private func about() {
        let alert = NSAlert()
        alert.messageText = "チャイム"
        alert.informativeText = "data/ に書いた予定どおりに"
                              + "学校のチャイムを鳴らす。\n\n"
                              + "フォルダ: \(Runner.root?.path ?? "見つからない")"
        alert.runModal()
    }

    @objc private func openReadme() {
        if let root = Runner.root {
            NSWorkspace.shared.open(root.appendingPathComponent("README.md"))
        }
    }

    // MARK: メニューバーの表示

    private func updateTitle() {
        guard let button = statusItem.button else { return }
        let paused = !(engine.config?.enabled ?? true)
        let symbol = paused ? "bell.slash" : "bell.fill"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "チャイム")
        button.image?.isTemplate = true

        if engine.errorText != nil {
            button.title = " !"
        } else if let rung = engine.lastRung, Date().timeIntervalSince(rung.at) < 120 {
            button.title = " " + String(rung.label.prefix(16))
        } else if let next = engine.next, !paused {
            button.title = " " + next.time
        } else {
            button.title = ""
        }
    }

    // MARK: メニューの中身

    func menuNeedsUpdate(_ menu: NSMenu) {
        engine.reload()
        menu.removeAllItems()

        if let error = engine.errorText {
            add(menu, error, enabled: false)
            menu.addItem(.separator())
            addAction(menu, "予定のウインドウを開く", #selector(showMainWindow))
            addAction(menu, "設定…", #selector(openSettings))
            addAction(menu, "チャイムを終了", #selector(quit), key: "q")
            return
        }

        guard let today = engine.today else { return }
        let label = today.calendar_label.isEmpty ? "" : "  \(today.calendar_label)"
        add(menu, "\(today.date) (\(today.weekday))\(label)", enabled: false)
        add(menu, today.title ?? "予定なし（今日は鳴らない）", enabled: false, bold: true)
        if let note = today.note {
            add(menu, note, enabled: false, small: true)
        }
        menu.addItem(.separator())

        let now = Date()
        let nextTime = engine.next?.at
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        parser.locale = Locale(identifier: "en_US_POSIX")

        for event in today.events {
            let at = parser.date(from: event.at) ?? now
            let mark: String
            if let nextTime, at == nextTime { mark = "▶︎" }
            else if at < now { mark = "✓" }
            else { mark = "  " }
            let tag = event.sound == "night" ? "  ♪" : (event.sound == "pre" ? "  ・" : "")
            add(menu, "\(mark) \(event.time)  \(event.label)\(tag)",
                enabled: false, bold: at == nextTime)
        }
        if today.events.isEmpty {
            add(menu, "  （チャイムなし）", enabled: false)
        }

        menu.addItem(.separator())
        let paused = !(engine.config?.enabled ?? true)
        addAction(menu, paused ? "チャイムを再開" : "チャイムを一時停止", #selector(togglePause))
        addAction(menu, "今すぐ鳴らしてみる", #selector(testRing))
        menu.addItem(.separator())
        addAction(menu, "予定のウインドウを開く", #selector(showMainWindow))
        addAction(menu, "設定…", #selector(openSettings), key: ",")
        addAction(menu, "フォルダを開く", #selector(openFolder))
        addAction(menu, "予定を読み直す", #selector(reloadNow), key: "r")
        menu.addItem(.separator())
        addAction(menu, "チャイムを終了", #selector(quit), key: "q")
    }

    private func add(_ menu: NSMenu, _ title: String,
                     enabled: Bool, bold: Bool = false, small: Bool = false) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = enabled
        var font = NSFont.menuFont(ofSize: small ? 10 : 0)
        if bold { font = NSFont.boldSystemFont(ofSize: font.pointSize) }
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: font,
                         .foregroundColor: small ? NSColor.secondaryLabelColor : NSColor.labelColor])
        menu.addItem(item)
    }

    @discardableResult
    private func addAction(_ menu: NSMenu, _ title: String,
                           _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    // MARK: 操作

    @objc private func togglePause() {
        engine.patch(["enabled": !(engine.config?.enabled ?? true)])
        engine.stopSound()
        updateTitle()
    }

    @objc private func testRing() {
        engine.play("chime")
    }

    @objc private func reloadNow() {
        engine.reload()
        updateTitle()
    }

    @objc private func openFolder() {
        if let root = Runner.root { NSWorkspace.shared.open(root) }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 500),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered, defer: false)
            window.title = "チャイムの設定"
            window.contentView = NSHostingView(rootView: SettingsView(engine: engine))
            window.center()
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
