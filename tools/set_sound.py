#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""手持ちの音声ファイルをチャイムの音として入れる。

    python3 tools/set_sound.py chime  ~/Desktop/bell.mp3
    python3 tools/set_sound.py pre    ~/Desktop/bell.mp3 --end 5.7
    python3 tools/set_sound.py night  ~/Desktop/owari.wav

役割は3つ:
    chime   通常のチャイム（各ブロックの開始時刻）
    pre     予鈴（設定で「◯分前」を選んだときだけ鳴る）
    night   消灯（21:30）

mp3 でも m4a でも wav でも、macOS が読める形式なら何でもよい。
やること: wav に変換 → 指定範囲を切り出す → 前後の無音を落とす →
          音量をそろえる → 終わりをフェードアウト → sounds/ に置く。
出どころは sounds/SOURCE.txt に記録する。
"""

import argparse
import datetime
import pathlib
import subprocess
import sys
import tempfile
import wave

try:
    import numpy as np
except ImportError:
    sys.exit("numpy が要る（/usr/bin/python3 には入っている）")

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOUNDS = ROOT / "sounds"
RECORD = SOUNDS / "SOURCE.txt"

ROLES = {
    "chime": ("chime.wav", "通常のチャイム"),
    "pre": ("chime_pre.wav", "予鈴"),
    "night": ("chime_night.wav", "消灯"),
}

SILENCE_DB = -60      # これより静かな前後は落とす（ピーク比）
LEAD_IN = 0.03        # 切り出しの頭に入れるフェードイン（秒）


def read_audio(path):
    """macOS の afconvert で wav にしてから読む。"""
    with tempfile.TemporaryDirectory() as tmp:
        wav = pathlib.Path(tmp) / "in.wav"
        subprocess.run(["/usr/bin/afconvert", "-f", "WAVE", "-d", "LEI16@44100",
                        str(path), str(wav)],
                       check=True, capture_output=True)
        with wave.open(str(wav)) as w:
            raw = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2")
            data = raw.astype(np.float64) / 32768
            ch, sr = w.getnchannels(), w.getframerate()
    return data.reshape(-1, ch), sr


def write_audio(path, data, sr):
    pcm = np.clip(data, -1.0, 1.0).reshape(-1) * 32767.0
    with wave.open(str(path), "wb") as w:
        w.setnchannels(data.shape[1])
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(pcm.astype("<i2").tobytes())


def trim_silence(data, sr):
    """前後の聞こえない部分を落とす。"""
    mono = data.mean(axis=1)
    if not np.any(mono):
        return data
    window = max(int(sr * 0.02), 1)
    energy = np.convolve(mono ** 2, np.ones(window) / window, mode="same")
    audible = np.flatnonzero(energy > 10 ** (SILENCE_DB / 10) * energy.max())
    if not len(audible):
        return data
    start = max(0, audible[0] - int(sr * 0.01))
    end = min(len(data), audible[-1] + int(sr * 0.15))
    return data[start:end]


def process(data, sr, start, end, peak, fade):
    if start:
        data = data[int(sr * start):]
    if end:
        data = data[:int(sr * (end - (start or 0)))]
    data = trim_silence(data, sr).copy()
    if not len(data):
        sys.exit("切り出した範囲に音が入っていない")

    # 曲の途中から切り出したときに頭が「ブツッ」と鳴らないように
    lead = min(int(sr * LEAD_IN), len(data))
    data[:lead] *= (0.5 - 0.5 * np.cos(np.pi * np.arange(lead) / lead))[:, None]

    top = float(np.abs(data).max()) or 1.0
    data *= peak / top

    n = min(int(sr * fade), len(data))
    data[len(data) - n:] *= (0.5 + 0.5 * np.cos(np.pi * np.arange(n) / n))[:, None]
    return data


def record(role, source, out, seconds, channels):
    lines = []
    if RECORD.exists():
        lines = [l for l in RECORD.read_text(encoding="utf-8").splitlines()
                 if not l.startswith(out + " ")]
    lines = [l for l in lines if l.strip() and not l.startswith("#")]
    lines.append("%-16s %-8s %5.2f秒 %dch  ← %s" % (out, role, seconds, channels, source))
    head = ["# チャイムの音の出どころ",
            "# 入れ直すには: python3 tools/set_sound.py <chime|pre|night> <音声ファイル>",
            "# 最終更新 " + datetime.date.today().isoformat(), ""]
    RECORD.write_text("\n".join(head + sorted(lines)) + "\n", encoding="utf-8")


def main():
    p = argparse.ArgumentParser(description="手持ちの音声をチャイムの音として入れる")
    p.add_argument("role", choices=list(ROLES))
    p.add_argument("source", help="音声ファイル (mp3 / m4a / wav など)")
    p.add_argument("--start", type=float, default=0.0, help="ここから切り出す（秒）")
    p.add_argument("--end", type=float, default=None, help="ここまで切り出す（秒）")
    p.add_argument("--peak", type=float, default=0.92, help="そろえる音量 (0-1)")
    p.add_argument("--fade", type=float, default=0.45, help="終わりを消す長さ（秒）")
    args = p.parse_args()

    src = pathlib.Path(args.source).expanduser()
    if not src.exists():
        sys.exit("見つからない: %s" % src)

    data, sr = read_audio(src)
    print("読み込み: %s  %.2f秒 %dch" % (src.name, len(data) / sr, data.shape[1]))

    data = process(data, sr, args.start, args.end, args.peak, args.fade)
    out, label = ROLES[args.role]
    SOUNDS.mkdir(exist_ok=True)
    write_audio(SOUNDS / out, data, sr)
    record(args.role, src.name, out, len(data) / sr, data.shape[1])
    print("→ sounds/%s  (%s)  %.2f秒 %dch  最大 %.2f"
          % (out, label, len(data) / sr, data.shape[1], args.peak))


if __name__ == "__main__":
    main()
