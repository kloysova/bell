#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""学習カレンダーに合わせて学校のチャイムを鳴らすだけのソフト。

data/calendar.json（日付 → その日の区分）と data/routines.json
（区分 → 鳴らす時刻と内容）を見て、その日の区切り時刻に
ウェストミンスターのチャイム（キーンコーンカーンコーン）を鳴らす。

標準ライブラリだけで動く。macOS の afplay / osascript を使用。

    python3 chime.py today       今日の予定とチャイム時刻
    python3 chime.py run         鳴らし続ける（Ctrl+C で終了）
    python3 chime.py install     ログイン時に自動起動する
"""

import argparse
import datetime as dt
import json
import math
import os
import pathlib
import subprocess
import sys
import time
import unicodedata
import wave

ROOT = pathlib.Path(__file__).resolve().parent
DATA = ROOT / "data"
SOUNDS = ROOT / "sounds"
LOGS = ROOT / "logs"
CONFIG_PATH = DATA / "config.json"
STATE_PATH = DATA / "state.json"

LAUNCH_LABEL = "local.gakushu-chime"
PLIST_PATH = pathlib.Path.home() / "Library" / "LaunchAgents" / (LAUNCH_LABEL + ".plist")

WD = "月火水木金土日"

DEFAULT_CONFIG = {
    "_note": "このファイルは自由に編集してよい。chime.py run 中でも次のチャイムから反映される。",
    "enabled": True,
    "volume": 1.0,
    "notify": True,
    "pre_chime_minutes": 0,
    "grace_seconds": 120,
    "_date_overrides": "日課タイプを手動で上書き。例 {\"2026-09-21\": \"休養調整日\"}",
    "date_overrides": {},
    "_disabled_dates": "その日だけ全部鳴らさない。例 [\"2026-12-31\"]",
    "disabled_dates": [],
    "_mute_times": "この時刻のチャイムだけ鳴らさない。例 [\"08:35\", \"12:25\", \"13:10\"]",
    "mute_times": [],
}

# 月間カレンダーのラベルのうち、通常の学校日として扱うもの
SCHOOL_MARKS = {"2学期開始", "3学期開始", "修了"}
VACATIONS = {"夏休み", "冬休み", "春休み"}


# ---------------------------------------------------------------- データ読み込み

def _load_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def _load_required(name):
    """calendar.json / routines.json を読む。無ければ作り方を案内して終わる。"""
    path = DATA / name
    if not path.exists():
        sys.exit(
            "data/%s が無い。\n"
            "このリポジトリに日課データは同梱していないので、自分で用意する。\n"
            "書き方は README の「data/ を用意する」を見る。" % name
        )
    return _load_json(path)


def load_calendar():
    return _load_required("calendar.json")


def load_routines():
    return _load_required("routines.json")


def load_config():
    if not CONFIG_PATH.exists():
        DATA.mkdir(exist_ok=True)
        with open(CONFIG_PATH, "w", encoding="utf-8") as f:
            json.dump(DEFAULT_CONFIG, f, ensure_ascii=False, indent=1)
            f.write("\n")
        return dict(DEFAULT_CONFIG)
    cfg = dict(DEFAULT_CONFIG)
    try:
        cfg.update(_load_json(CONFIG_PATH))
    except (ValueError, OSError) as e:
        log("config.json が読めないので初期設定で動かす: %s" % e)
    return cfg


def load_state():
    try:
        return _load_json(STATE_PATH)
    except (ValueError, OSError):
        return {}


def save_state(state):
    DATA.mkdir(exist_ok=True)
    tmp = STATE_PATH.with_suffix(".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f, ensure_ascii=False, indent=1)
    tmp.replace(STATE_PATH)


# ---------------------------------------------------------------- 日課の判定

def day_type(date, calendar, cfg):
    """その日の日課タイプ名を返す。予定が無い日は None。"""
    key = date.isoformat()
    if key in cfg.get("disabled_dates", []):
        return None
    override = cfg.get("date_overrides", {}).get(key)
    if override:
        return override

    period = calendar["study_period"]
    if not (period["start"] <= key <= period["end"]):
        return None

    label = calendar["days"].get(key)
    if label is None:
        return None
    toks = label.split()

    # 長期休暇（A/B/休）が最優先。祝日と重なっても A/B/休 のサイクルを維持する
    for i, t in enumerate(toks):
        if t in VACATIONS and i + 1 < len(toks):
            nxt = toks[i + 1]
            if nxt in ("A", "B"):
                return "長期休暇" + nxt
            if nxt == "休":
                return "長期休暇休"

    if "考査" in label:
        return "定期考査日"
    if "休養調整日" in label:
        return "休養調整日"

    # 残ったラベルは祝日名（海の日・元日など）
    if [t for t in toks if t not in SCHOOL_MARKS]:
        return "祝日"

    wd = date.weekday()
    if wd <= 4:
        return "学校平日"
    if wd == 5:
        return "学校土曜"
    return "通常日曜"


def day_events(date, calendar, routines, cfg):
    """その日のチャイム一覧 [(datetime, ラベル, 音の種類), ...] を返す。"""
    name = day_type(date, calendar, cfg)
    if not name:
        return []
    routine = routines["routines"].get(name)
    if not routine:
        log("未知の日課タイプ: %r（config.json の date_overrides を確認）" % name)
        return []

    tasks = routines.get("weekday_tasks", {}).get(str(date.weekday()), {})
    muted = set(cfg.get("mute_times", []))

    out = []
    for ev in routine["events"]:
        if ev["time"] in muted:
            continue
        hh, mm = ev["time"].split(":")
        when = dt.datetime.combine(date, dt.time(int(hh), int(mm)))
        label = ev["label"]
        extra = tasks.get(ev.get("task", ""))
        if extra:
            label = "%s ／ %s" % (label, extra)
        out.append((when, label, ev.get("sound", "chime")))

    pre = int(cfg.get("pre_chime_minutes") or 0)
    if pre > 0:
        fixed = {w for w, _, _ in out}
        for when, label, _s in list(out):
            p = when - dt.timedelta(minutes=pre)
            if p.date() == date and p not in fixed:
                out.append((p, "まもなく %s: %s" % (when.strftime("%H:%M"), label), "pre"))

    out.sort(key=lambda x: x[0])
    return out


def next_event(after, calendar, routines, cfg, horizon_days=400):
    """after より後の最初のチャイムを返す。無ければ None。"""
    date = after.date()
    for _ in range(horizon_days):
        for ev in day_events(date, calendar, routines, cfg):
            if ev[0] > after:
                return ev
        date += dt.timedelta(days=1)
    return None


# ---------------------------------------------------------------- 音の生成

SR = 44100

# 日本の学校のチャイム（ウェストミンスターの鐘）。
#   前半 キーン コーン カーン コーン = ミ ド レ ソ
#   後半 キーン コーン カーン コーン = ソ レ ミ ド
# ここで作る音は sounds/ が空のときの予備。普段は sounds/ に置いた録音を鳴らす。
# 音の入れ替えは tools/set_sound.py。
PHRASE_A = ["E5", "C5", "D5", "G4"]
PHRASE_B = ["G4", "D5", "E5", "C5"]
PHRASE_END = ["G5", "D5", "B4", "G4"]   # 消灯（放送終了の下降形）

NOTES = {"G4": 392.00, "B4": 493.88, "C5": 523.25,
         "D5": 587.33, "E5": 659.26, "G5": 783.99}

# 管鐘（チューブラーベル）の倍音構成 (基音に対する倍率, 音量, 減衰時定数[秒])
# 基音を強く長く、上の倍音ほど小さく速く消えるようにすると澄んだ鐘の音になる。
PARTIALS = [
    (0.500, 0.060, 4.5),    # ハム音。低い胴鳴りで厚みを出す
    (1.000, 1.000, 3.4),    # 基音。聞こえる高さはここ
    (2.000, 0.420, 2.5),    # オクターブ
    (3.000, 0.170, 1.8),
    (4.000, 0.085, 1.25),
    (5.430, 0.048, 0.75),   # ここから上が金属的な響き
    (6.790, 0.026, 0.48),
    (8.210, 0.013, 0.32),   # 打った瞬間のきらめき
]
DETUNE = 1.0006             # 基音をわずかにずらして重ね、うなりで柔らげる
ATTACK = 0.003              # 3ms で立ち上げる（プツッというノイズを防ぐ）
FADE = 1.5                  # 終わりの1.5秒で消す（切れ際のプツッを防ぐ）

# 反射音。左右で遅れをずらすと、狭い部屋で鳴っている感じが消えて左右に広がる。
REFLECTIONS = {
    "L": [(0.023, 0.085), (0.037, 0.070), (0.053, 0.055),
          (0.071, 0.043), (0.097, 0.032), (0.131, 0.023)],
    "R": [(0.029, 0.080), (0.043, 0.066), (0.061, 0.052),
          (0.079, 0.041), (0.107, 0.030), (0.141, 0.022)],
}

try:
    import numpy as _np
except ImportError:                                          # pragma: no cover
    _np = None


def _note_np(freq, dur):
    n = int(SR * dur)
    t = _np.arange(n, dtype=_np.float64) / SR
    out = _np.zeros(n)
    for ratio, amp, tau in PARTIALS:
        f = freq * ratio
        if f > SR * 0.45:
            continue
        env = amp * _np.exp(-t / tau)
        if ratio == 1.0:
            out += 0.5 * env * (_np.sin(2 * math.pi * f * t)
                                + _np.sin(2 * math.pi * f * DETUNE * t))
        else:
            out += env * _np.sin(2 * math.pi * f * t)
    a = int(SR * ATTACK)
    out[:a] *= 0.5 - 0.5 * _np.cos(math.pi * _np.arange(a) / a)
    return out


def _note_py(freq, dur):
    """numpy が無いときの代わり。遅いが結果は同じ。"""
    n = int(SR * dur)
    out = [0.0] * n
    for ratio, amp, tau in PARTIALS:
        f = freq * ratio
        if f > SR * 0.45:
            continue
        w = 2 * math.pi * f / SR
        w2 = w * DETUNE
        for i in range(n):
            env = amp * math.exp(-i / (tau * SR))
            if ratio == 1.0:
                out[i] += 0.5 * env * (math.sin(w * i) + math.sin(w2 * i))
            else:
                out[i] += env * math.sin(w * i)
    a = int(SR * ATTACK)
    for i in range(min(a, n)):
        out[i] *= 0.5 - 0.5 * math.cos(math.pi * i / a)
    return out


def _render(names, starts, tail):
    """names の音を starts[秒] の位置に重ねて、左右2本にして返す。"""
    length = int(SR * (max(starts) + tail))
    make = _note_np if _np is not None else _note_py
    note_of = {name: make(NOTES[name], tail) for name in set(names)}

    if _np is not None:
        dry = _np.zeros(length)
        for name, start in zip(names, starts):
            off = int(SR * start)
            note = note_of[name][:length - off]
            dry[off:off + len(note)] += note

        fade = min(int(SR * FADE), length)
        curve = 0.5 + 0.5 * _np.cos(math.pi * _np.arange(fade) / fade)
        channels = []
        for side in ("L", "R"):
            ch = dry.copy()
            for delay, gain in REFLECTIONS[side]:
                d = int(SR * delay)
                ch[d:] += gain * dry[:-d]
            ch[length - fade:] *= curve
            channels.append(ch)
        peak = max(float(_np.max(_np.abs(c))) for c in channels) or 1.0
        return [c * (0.85 / peak) for c in channels]

    dry = [0.0] * length
    for name, start in zip(names, starts):
        off = int(SR * start)
        for i, v in enumerate(note_of[name]):
            if off + i < length:
                dry[off + i] += v
    fade = min(int(SR * FADE), length)
    channels = []
    for side in ("L", "R"):
        ch = list(dry)
        for delay, gain in REFLECTIONS[side]:
            d = int(SR * delay)
            for i in range(d, length):
                ch[i] += gain * dry[i - d]
        for i in range(fade):
            ch[length - fade + i] *= 0.5 + 0.5 * math.cos(math.pi * i / fade)
        channels.append(ch)
    peak = max(max(abs(v) for v in c) for c in channels) or 1.0
    return [[v * 0.85 / peak for v in c] for c in channels]


def _write_wav(path, channels):
    path.parent.mkdir(exist_ok=True)
    left, right = channels
    if _np is not None:
        stereo = _np.empty(len(left) * 2)
        stereo[0::2] = _np.clip(left, -1.0, 1.0)
        stereo[1::2] = _np.clip(right, -1.0, 1.0)
        frames = (stereo * 32767.0).astype("<i2").tobytes()
    else:
        buf = bytearray()
        for l, r in zip(left, right):
            for v in (l, r):
                buf += int(max(-1.0, min(1.0, v)) * 32767).to_bytes(2, "little", signed=True)
        frames = bytes(buf)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(frames)


SOUND_FILES = {
    "chime": "chime.wav",
    "pre": "chime_pre.wav",
    "night": "chime_night.wav",
}


def _sequence(phrases, step, gap):
    """step = 音の間隔、gap = フレーズとフレーズの間に足す時間。"""
    names, starts, t = [], [], 0.0
    for i, phrase in enumerate(phrases):
        if i:
            t += gap
        for name in phrase:
            names.append(name)
            starts.append(t)
            t += step
    return names, starts


def build_sounds(force=False):
    """sounds/ に音が無いときだけ作る。録音を入れるのは tools/set_sound.py。"""
    SOUNDS.mkdir(exist_ok=True)
    specs = {
        "chime": (_sequence([PHRASE_A, PHRASE_B], 0.58, 1.85), 3.5),
        "pre": (_sequence([PHRASE_A], 0.58, 0.0), 3.0),
        "night": (_sequence([PHRASE_END], 0.56, 0.0), 3.2),
    }
    missing = [k for k in specs if force or not (SOUNDS / SOUND_FILES[k]).exists()]
    if not missing:
        return
    print("sounds/ に音が無いので合成音を作る。"
          "音を入れ替えるには python3 tools/set_sound.py", flush=True)
    if _np is None:
        print("（numpy が無いので少し時間がかかる）", flush=True)
    for key in missing:
        names, starts = specs[key][0]
        print("生成中: %s" % SOUND_FILES[key], flush=True)
        _write_wav(SOUNDS / SOUND_FILES[key], _render(names, starts, specs[key][1]))


# ---------------------------------------------------------------- 再生・通知

def play(sound, cfg, wait=False):
    path = SOUNDS / SOUND_FILES.get(sound, SOUND_FILES["chime"])
    if not path.exists():
        build_sounds()
    vol = str(float(cfg.get("volume", 1.0)))
    try:
        p = subprocess.Popen(["/usr/bin/afplay", "-v", vol, str(path)],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if wait:
            p.wait()
    except OSError as e:
        log("afplay を起動できない: %s" % e)


def _as_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def notify(title, text):
    script = "display notification %s with title %s" % (_as_str(text), _as_str(title))
    try:
        subprocess.run(["/usr/bin/osascript", "-e", script],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
    except (OSError, subprocess.SubprocessError):
        pass


def log(msg):
    print("[%s] %s" % (dt.datetime.now().strftime("%m-%d %H:%M:%S"), msg), flush=True)


# ---------------------------------------------------------------- 表示

def describe_day(date, calendar, routines, cfg):
    name = day_type(date, calendar, cfg)
    label = calendar["days"].get(date.isoformat(), "")
    head = "%s (%s)" % (date.isoformat(), WD[date.weekday()])
    if not name:
        return head, (label or "学習期間外"), None
    routine = routines["routines"].get(name)
    title = routine["title"] if routine else name
    return head, (label or "—"), title


def cmd_show(args, calendar, routines, cfg, date):
    head, label, title = describe_day(date, calendar, routines, cfg)
    print()
    print("  %s   カレンダー: %s" % (head, label))
    print("  日課: %s" % (title or "予定なし（チャイムは鳴らない）"))
    name = day_type(date, calendar, cfg)
    routine = routines["routines"].get(name) if name else None
    if routine and routine.get("note"):
        print("  ※ %s" % routine["note"])
    print()
    events = day_events(date, calendar, routines, cfg)
    now = dt.datetime.now()
    is_today = date == now.date()
    upcoming = [e for e in events if e[0] > now]
    nxt = upcoming[0] if (is_today and upcoming) else None
    for when, lbl, sound in events:
        if not is_today:
            mark = " "
        elif nxt and when == nxt[0]:
            mark = "→"
        else:
            mark = "·" if when > now else "済"
        tag = "  ♪消灯" if sound == "night" else ("  ・予鈴" if sound == "pre" else "")
        print("   %s %s  %s%s" % (mark, when.strftime("%H:%M"), lbl, tag))
    if not events:
        print("   （チャイムなし）")
    print()
    if date == now.date():
        ev = next_event(now, calendar, routines, cfg)
        if ev:
            delta = ev[0] - now
            h, rem = divmod(int(delta.total_seconds()), 3600)
            m = rem // 60
            when_txt = ev[0].strftime("%H:%M")
            if ev[0].date() != now.date():
                when_txt = ev[0].strftime("%m/%d %H:%M")
            print("  次のチャイム: %s  %s   （あと %d時間%d分）" % (when_txt, ev[1], h, m))
            print()
    return 0


def _pad(s, width):
    """全角文字を2桁として数えて右側を空白で埋める。"""
    w = sum(2 if unicodedata.east_asian_width(c) in "WFA" else 1 for c in s)
    return s + " " * max(0, width - w)


def cmd_week(args, calendar, routines, cfg):
    start = dt.date.today()
    days = int(args.days)
    print()
    for i in range(days):
        d = start + dt.timedelta(days=i)
        head, label, title = describe_day(d, calendar, routines, cfg)
        events = day_events(d, calendar, routines, cfg)
        times = " ".join(w.strftime("%H:%M") for w, _, _ in events)
        print("  %s  %s%s" % (head, _pad(title or "予定なし", 34),
                              label if label != "—" else ""))
        print("      %s" % (times or "（チャイムなし）"))
    print()
    return 0


# ---------------------------------------------------------------- 常駐

def cmd_run(args, calendar, routines, cfg):
    build_sounds()
    state = load_state()
    log("開始: %s" % ROOT)

    anchor_raw = state.get("anchor")
    anchor = None
    if anchor_raw:
        try:
            anchor = dt.datetime.fromisoformat(anchor_raw)
        except ValueError:
            anchor = None
    now = dt.datetime.now()
    grace = dt.timedelta(seconds=int(cfg.get("grace_seconds", 120)))
    if anchor is None or anchor < now - dt.timedelta(days=1) or anchor > now:
        anchor = now - grace

    ev = next_event(anchor, calendar, routines, cfg)
    if ev:
        log("次のチャイム: %s  %s" % (ev[0].strftime("%m/%d %H:%M"), ev[1]))

    while True:
        cfg = load_config()
        grace = dt.timedelta(seconds=int(cfg.get("grace_seconds", 120)))
        now = dt.datetime.now()

        # 時計が大きく巻き戻った場合の保険
        if anchor > now + dt.timedelta(minutes=5):
            anchor = now - grace

        ev = next_event(anchor, calendar, routines, cfg)
        if ev is None:
            time.sleep(300)
            continue

        when, label, sound = ev
        wait = (when - now).total_seconds()
        if wait > 0:
            time.sleep(min(wait, 30.0))
            continue

        if now - when <= grace:
            if cfg.get("enabled", True):
                log("♪ %s  %s" % (when.strftime("%H:%M"), label))
                play(sound, cfg)
                if cfg.get("notify", True):
                    notify("%s  チャイム" % when.strftime("%H:%M"), label)
            else:
                log("（停止中のため鳴らさない） %s %s" % (when.strftime("%H:%M"), label))
        else:
            log("時刻を過ぎているため飛ばす: %s %s" % (when.strftime("%m/%d %H:%M"), label))

        anchor = when
        state["anchor"] = anchor.isoformat()
        save_state(state)


# ---------------------------------------------------------------- launchd

PLIST = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>Label</key>
\t<string>{label}</string>
\t<key>ProgramArguments</key>
\t<array>
\t\t<string>{python}</string>
\t\t<string>{script}</string>
\t\t<string>run</string>
\t</array>
\t<key>WorkingDirectory</key>
\t<string>{root}</string>
\t<key>RunAtLoad</key>
\t<true/>
\t<key>KeepAlive</key>
\t<true/>
\t<key>StandardOutPath</key>
\t<string>{log}</string>
\t<key>StandardErrorPath</key>
\t<string>{err}</string>
</dict>
</plist>
"""


def _launchctl(*a):
    return subprocess.run(["/bin/launchctl"] + list(a),
                          capture_output=True, text=True)


def _domain():
    return "gui/%d" % os.getuid()


def cmd_install(args, calendar, routines, cfg):
    build_sounds()
    LOGS.mkdir(exist_ok=True)
    PLIST_PATH.parent.mkdir(parents=True, exist_ok=True)
    python = "/usr/bin/python3" if os.path.exists("/usr/bin/python3") else sys.executable
    PLIST_PATH.write_text(PLIST.format(
        label=LAUNCH_LABEL, python=python, script=str(ROOT / "chime.py"),
        root=str(ROOT), log=str(LOGS / "chime.log"), err=str(LOGS / "chime.err.log"),
    ), encoding="utf-8")

    _launchctl("bootout", "%s/%s" % (_domain(), LAUNCH_LABEL))
    r = _launchctl("bootstrap", _domain(), str(PLIST_PATH))
    if r.returncode != 0:
        r = _launchctl("load", "-w", str(PLIST_PATH))
    if r.returncode != 0:
        print("自動起動の登録に失敗した: %s" % (r.stderr.strip() or r.stdout.strip()))
        return 1
    print("自動起動を登録した。Mac のログイン時に自動で動く。")
    print("  設定ファイル : %s" % PLIST_PATH)
    print("  ログ         : %s" % (LOGS / "chime.log"))
    print("  解除         : python3 chime.py uninstall")
    return 0


def cmd_uninstall(args, calendar, routines, cfg):
    r = _launchctl("bootout", "%s/%s" % (_domain(), LAUNCH_LABEL))
    if r.returncode != 0:
        _launchctl("unload", "-w", str(PLIST_PATH))
    if PLIST_PATH.exists():
        PLIST_PATH.unlink()
    print("自動起動を解除した。")
    return 0


def cmd_status(args, calendar, routines, cfg):
    r = _launchctl("list", LAUNCH_LABEL)
    running = r.returncode == 0
    print()
    print("  自動起動 : %s" % ("登録済み・稼働中" if running else "未登録"))
    print("  鳴らす    : %s" % ("はい" if cfg.get("enabled", True) else "いいえ（config.json の enabled が false）"))
    print("  音量      : %s" % cfg.get("volume"))
    print("  通知      : %s" % ("あり" if cfg.get("notify", True) else "なし"))
    pre = int(cfg.get("pre_chime_minutes") or 0)
    print("  予鈴      : %s" % ("%d分前" % pre if pre else "なし"))
    if cfg.get("mute_times"):
        print("  消音時刻  : %s" % " ".join(cfg["mute_times"]))
    print()
    return cmd_show(args, calendar, routines, cfg, dt.date.today())


# ---------------------------------------------------------------- アプリ用 (JSON)

CONFIG_KEYS = ("enabled", "volume", "notify", "pre_chime_minutes", "grace_seconds",
               "date_overrides", "disabled_dates", "mute_times")


def _emit(obj):
    json.dump(obj, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


def cmd_agenda(args, calendar, routines, cfg):
    """チャイム.app が読む、解決済みの予定表。"""
    start = dt.date.fromisoformat(args.date) if args.date else dt.date.today()
    days = []
    for i in range(int(args.days)):
        d = start + dt.timedelta(days=i)
        name = day_type(d, calendar, cfg)
        routine = routines["routines"].get(name) if name else None
        days.append({
            "date": d.isoformat(),
            "weekday": WD[d.weekday()],
            "calendar_label": calendar["days"].get(d.isoformat(), ""),
            "day_type": name,
            "title": routine["title"] if routine else None,
            "note": routine.get("note") if routine else None,
            "events": [{"time": w.strftime("%H:%M"), "at": w.isoformat(timespec="seconds"),
                        "label": lb, "sound": s}
                       for w, lb, s in day_events(d, calendar, routines, cfg)],
        })
    return _emit({
        "generated_at": dt.datetime.now().isoformat(timespec="seconds"),
        "root": str(ROOT),
        "study_period": calendar["study_period"],
        "day_types": [{"key": k, "title": v["title"]}
                      for k, v in routines["routines"].items()],
        "config": {k: cfg.get(k) for k in CONFIG_KEYS},
        "days": days,
    })


def cmd_config_set(args, calendar, routines, cfg):
    """config.json に値を差し込む。コメント行(_note等)は残す。"""
    patch = json.loads(args.json)
    unknown = [k for k in patch if k not in CONFIG_KEYS]
    if unknown:
        return _emit({"ok": False, "error": "不明な設定項目: %s" % ", ".join(unknown)})
    current = dict(DEFAULT_CONFIG)
    if CONFIG_PATH.exists():
        current.update(_load_json(CONFIG_PATH))
    current.update(patch)
    with open(CONFIG_PATH, "w", encoding="utf-8") as f:
        json.dump(current, f, ensure_ascii=False, indent=1)
        f.write("\n")
    return _emit({"ok": True, "config": {k: current.get(k) for k in CONFIG_KEYS}})


def cmd_routine_set(args, calendar, routines, cfg):
    """1つの日課タイプのチャイム時刻表を差し替える。"""
    key = args.type
    if key not in routines["routines"]:
        return _emit({"ok": False, "error": "不明な日課タイプ: %s" % key})
    events = json.loads(args.json)
    cleaned = []
    for ev in events:
        try:
            hh, mm = str(ev["time"]).split(":")
            hh, mm = int(hh), int(mm)
            if not (0 <= hh < 24 and 0 <= mm < 60):
                raise ValueError
        except (KeyError, ValueError):
            return _emit({"ok": False, "error": "時刻の書き方が正しくない: %r" % ev.get("time")})
        label = str(ev.get("label", "")).strip()
        if not label:
            return _emit({"ok": False, "error": "%02d:%02d の内容が空" % (hh, mm)})
        sound = ev.get("sound", "chime")
        if sound not in SOUND_FILES:
            sound = "chime"
        item = {"time": "%02d:%02d" % (hh, mm), "label": label, "sound": sound}
        if ev.get("task"):
            item["task"] = ev["task"]
        cleaned.append(item)
    cleaned.sort(key=lambda e: e["time"])
    routines["routines"][key]["events"] = cleaned
    path = DATA / "routines.json"
    tmp = path.with_suffix(".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(routines, f, ensure_ascii=False, indent=1)
        f.write("\n")
    tmp.replace(path)
    return _emit({"ok": True, "events": cleaned})


def cmd_routines_get(args, calendar, routines, cfg):
    return _emit(routines)


def cmd_ring(args, calendar, routines, cfg):
    """アプリからの単発再生（音の確認用）。"""
    build_sounds()
    play(args.sound, cfg, wait=True)
    return 0


def cmd_test(args, calendar, routines, cfg):
    build_sounds()
    sound = args.sound
    print("再生: %s" % SOUND_FILES[sound])
    play(sound, cfg, wait=True)
    if cfg.get("notify", True):
        notify("チャイム（テスト）", "音が鳴れば正常")
    return 0


# ---------------------------------------------------------------- CLI

def main(argv=None):
    p = argparse.ArgumentParser(
        prog="chime.py",
        description="学習カレンダーに合わせて学校のチャイムを鳴らす",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="例:\n"
               "  python3 chime.py today                今日の予定\n"
               "  python3 chime.py today --date 2026-12-25\n"
               "  python3 chime.py week --days 10       先の予定\n"
               "  python3 chime.py run                  常駐して鳴らす\n"
               "  python3 chime.py test                 音の確認\n"
               "  python3 chime.py install / uninstall   自動起動\n")
    sub = p.add_subparsers(dest="cmd")

    sp = sub.add_parser("today", help="今日（または指定日）の予定とチャイム時刻")
    sp.add_argument("--date", help="YYYY-MM-DD")
    sp = sub.add_parser("week", help="この先の日課一覧")
    sp.add_argument("--days", default=7, type=int)
    sub.add_parser("run", help="常駐してチャイムを鳴らす")
    sub.add_parser("status", help="状態を表示")
    sp = sub.add_parser("test", help="チャイム音を鳴らしてみる")
    sp.add_argument("sound", nargs="?", default="chime", choices=list(SOUND_FILES))
    sub.add_parser("install", help="ログイン時の自動起動を登録")
    sub.add_parser("uninstall", help="自動起動を解除")
    sp = sub.add_parser("sounds", help="チャイム音を作り直す")
    sp.add_argument("--force", action="store_true")

    # チャイム.app が使う JSON 入出力
    sp = sub.add_parser("agenda", help="解決済みの予定表をJSONで出す（アプリ用）")
    sp.add_argument("--days", default=3, type=int)
    sp.add_argument("--date")
    sub.add_parser("routines-get", help="routines.json をそのまま出す（アプリ用）")
    sp = sub.add_parser("config-set", help="設定を書き換える（アプリ用）")
    sp.add_argument("--json", required=True)
    sp = sub.add_parser("routine-set", help="日課の時刻表を書き換える（アプリ用）")
    sp.add_argument("--type", required=True)
    sp.add_argument("--json", required=True)
    sp = sub.add_parser("ring", help="指定した音を1回鳴らす（アプリ用）")
    sp.add_argument("sound", nargs="?", default="chime", choices=list(SOUND_FILES))

    args = p.parse_args(argv)
    cmd = args.cmd or "today"

    calendar = load_calendar()
    routines = load_routines()
    cfg = load_config()

    if cmd == "today":
        date = dt.date.fromisoformat(args.date) if getattr(args, "date", None) else dt.date.today()
        return cmd_show(args, calendar, routines, cfg, date)
    if cmd == "week":
        return cmd_week(args, calendar, routines, cfg)
    if cmd == "run":
        return cmd_run(args, calendar, routines, cfg)
    if cmd == "status":
        return cmd_status(args, calendar, routines, cfg)
    if cmd == "test":
        return cmd_test(args, calendar, routines, cfg)
    if cmd == "install":
        return cmd_install(args, calendar, routines, cfg)
    if cmd == "uninstall":
        return cmd_uninstall(args, calendar, routines, cfg)
    if cmd == "sounds":
        build_sounds(force=args.force)
        return 0
    if cmd == "agenda":
        return cmd_agenda(args, calendar, routines, cfg)
    if cmd == "routines-get":
        return cmd_routines_get(args, calendar, routines, cfg)
    if cmd == "config-set":
        return cmd_config_set(args, calendar, routines, cfg)
    if cmd == "routine-set":
        return cmd_routine_set(args, calendar, routines, cfg)
    if cmd == "ring":
        return cmd_ring(args, calendar, routines, cfg)
    p.print_help()
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\n終了")
