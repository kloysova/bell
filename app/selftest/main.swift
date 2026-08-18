// アプリ本体（Chime.swift）と chime.py のやり取りを画面なしで確認する。
// 使い方: ./build_app.sh --test
import AppKit

var failures = 0

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print("\(ok ? "  OK  " : "  NG  ") \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
    if !ok { failures += 1 }
}

print("チャイム.app 自己診断")
print("")

// 1. フォルダを見つけられるか
check("chime.py のフォルダを見つけた", Runner.root != nil, Runner.root?.path ?? "")

// 予定データがまだ無いときは、ここから先は検査できない。
if Runner.needsSetup {
    print("")
    print("data/ がまだ無いので、予定まわりの検査は省略した。")
    print("チャイム.app を開いて最初の画面から作るか、次を実行する:")
    print("  python3 chime.py init --start 2026-04-06 --end 2027-03-20")
    exit(failures == 0 ? 0 : 1)
}

// 2. agenda の JSON を Swift の型に取り込めるか
var agenda: Agenda?
do {
    agenda = try Runner.json(Agenda.self, ["agenda", "--days", "3"])
    check("agenda の JSON を読み込んだ", true, "\(agenda!.days.count)日分")
} catch {
    check("agenda の JSON を読み込んだ", false, error.localizedDescription)
}

if let agenda {
    check("日課タイプが9種類", agenda.day_types.count == 9,
          agenda.day_types.map(\.key).joined(separator: " "))
    check("設定を読めた", agenda.config.volume > 0,
          "音量 \(agenda.config.volume) / 通知 \(agenda.config.notify)")

    let today = agenda.days[0]
    check("今日を判定できた", today.day_type != nil,
          "\(today.date) (\(today.weekday)) \(today.calendar_label) → \(today.title ?? "なし")")

    // 3. 時刻文字列を Date に戻せるか（メニュー表示とタイマーの土台）
    let parser = DateFormatter()
    parser.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    parser.locale = Locale(identifier: "en_US_POSIX")
    let parsed = agenda.days.flatMap { $0.events }.compactMap { parser.date(from: $0.at) }
    let total = agenda.days.reduce(0) { $0 + $1.events.count }
    check("全イベントの時刻を解釈できた", parsed.count == total, "\(parsed.count)/\(total)")
    check("時刻が昇順に並んでいる", parsed == parsed.sorted())

    if let first = today.events.first, let at = parser.date(from: first.at) {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        check("先頭イベントの時刻が一致", f.string(from: at).hasSuffix(first.time),
              "\(f.string(from: at)) / \(first.time)")
    }
}

// 4. 音のファイルが揃っているか
if let root = Runner.root {
    for name in ["chime.wav", "chime_pre.wav", "chime_night.wav"] {
        let url = root.appendingPathComponent("sounds/\(name)")
        let sound = NSSound(contentsOf: url, byReference: true)
        check("音を開けた \(name)", sound != nil)
    }
}

// 5. 通知を出せるか（実際に1件出る）
check("通知を出せた", postNotification(title: "チャイム（自己診断）", body: "この通知が出れば正常"))

// 6. routines.json を編集画面の型に取り込めるか
do {
    let file = try Runner.json(RoutinesFile.self, ["routines-get"])
    let a = file.routines["長期休暇A"]
    check("routines.json を読み込んだ", a != nil,
          "長期休暇A は \(a?.events.count ?? 0) 行")
    let firstTime = a?.events.first?.time ?? ""
    check("編集用の型に時刻と内容が入っている",
          firstTime.range(of: "^[0-9]{2}:[0-9]{2}$", options: .regularExpression) != nil
              && !(a?.events.first?.label ?? "").isEmpty,
          a.map { "\($0.events.first!.time) \($0.events.first!.label)" } ?? "")
} catch {
    check("routines.json を読み込んだ", false, error.localizedDescription)
}

// 7. カレンダー画面: 読み出しと、わりあての往復ができるか
do {
    let file = try Runner.json(CalendarFile.self,
                               ["calendar-get", "--start", "2026-08-01", "--days", "42"])
    check("カレンダーを読み込んだ", file.days.count == 42,
          "\(file.study_period.start) 〜 \(file.study_period.end) / \(file.days.count)マス")

    // 期間内の日には必ず日課が決まる（何もわりあてていなくても曜日どおりになる）
    let inPeriod = file.days.filter {
        $0.date >= file.study_period.start && $0.date <= file.study_period.end
    }
    check("期間内の日にはすべて日課がある",
          !inPeriod.isEmpty && inPeriod.allSatisfy { $0.day_type != nil },
          "\(inPeriod.count)日を確認")

    // わりあて → 反映 → 取り消し が往復するか。元の状態は必ず戻す。
    /// 画面の「わりあて」と同じ経路（calendar-set）を叩く。
    func assign(_ date: String, _ type: String) throws -> Bool {
        let patch = ["types": [date: type]]
        let text = String(data: try JSONSerialization.data(withJSONObject: patch),
                          encoding: .utf8)!
        let out = try Runner.run(["calendar-set", "--json", text])
        let obj = try JSONSerialization.jsonObject(with: out) as? [String: Any]
        return obj?["ok"] as? Bool == true
    }

    if let target = inPeriod.first(where: { $0.assigned == nil }),
       let want = file.day_types.first(where: { $0.key != target.day_type }) {
        let ok = try assign(target.date, want.key)
        let after = try Runner.json(CalendarFile.self,
                                    ["calendar-get", "--start", target.date, "--days", "1"])
        check("日付に日課をわりあてられた",
              ok && after.days.first?.assigned == want.key,
              "\(target.date) → \(want.title)")

        // 空文字でわりあてを取り消し、元の状態に戻す
        let cleared = try assign(target.date, "")
        let restored = try Runner.json(CalendarFile.self,
                                       ["calendar-get", "--start", target.date, "--days", "1"])
        check("わりあてを取り消して元に戻せた",
              cleared && restored.days.first?.assigned == nil
                  && restored.days.first?.day_type == target.day_type,
              "\(target.date) → \(restored.days.first?.title ?? "なし")")
    } else {
        check("わりあてを試せる日があった", false, "空きの日が見つからない")
    }

    // 知らない日課タイプは弾かれるか
    check("知らない日課タイプは拒まれる",
          try assign("2026-08-01", "存在しない日課") == false)
} catch {
    check("カレンダーを読み込んだ", false, error.localizedDescription)
}

print("")
print(failures == 0 ? "すべて通った。" : "\(failures) 件失敗した。")
exit(failures == 0 ? 0 : 1)
