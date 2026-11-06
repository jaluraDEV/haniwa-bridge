#!/usr/bin/env python3
import os
import sys
import subprocess
import glob
import re
from PIL import Image
import numpy as np

SCENES = [
    ("Logo", "captures/frame_60.acfp"),
    ("Titel", "captures/frame_150.acfp"),
    ("Intro-Zugfahrt", "captures/scene_train.acfp"),
    ("Dorf Tag", "captures/scene_village_day.acfp"),
    ("Dorf Nacht", "captures/scene_village_night.acfp"),
    ("Innenraum Shop", "captures/scene_interior.acfp"),
    ("Innenraum Haus", "captures/scene_house.acfp"),
    ("Nebel / Regen", "captures/scene_fog.acfp"),
    ("Zug-Innenraum Tür", "captures/scene_train_door.acfp"),
    ("Gepflasterter Weg", "captures/scene_path.acfp"),
    ("Namenseingabe Tastatur", "captures/scene_keyboard.acfp"),
    ("Gleise / Bahnhof", "captures/scene_station.acfp"),
    ("Tom Nook Dialog", "captures/scene_tom_nook.acfp"),
]

def channel_ssim(c1, c2):
    c1 = c1.flatten()
    c2 = c2.flatten()
    mu1, mu2 = np.mean(c1), np.mean(c2)
    var1, var2 = np.var(c1), np.var(c2)
    cov = np.cov(c1, c2)[0, 1]
    k1, k2, L = 0.01, 0.03, 255.0
    c1_sq, c2_sq = (k1 * L) ** 2, (k2 * L) ** 2
    return ((2 * mu1 * mu2 + c1_sq) * (2 * cov + c2_sq)) / ((mu1 ** 2 + mu2 ** 2 + c1_sq) * (var1 + var2 + c2_sq))

def eval_one(name, acfp_path):
    base_name = os.path.splitext(os.path.basename(acfp_path))[0]
    gl_bmp = f"scratch/{base_name}_gl.bmp"
    gd_png = f"scratch/{base_name}_gd.png"
    diff_png = f"scratch/{base_name}_diff.png"

    # 1. GL Replay
    gl_cmd = ["tools/acfp_replay.exe", acfp_path, gl_bmp, "port/pc/shaders"]
    gl_res = subprocess.run(gl_cmd, capture_output=True, text=True)
    draws = 0
    m = re.search(r"Executed (\d+) draw calls", gl_res.stdout)
    if m: draws = int(m.group(1))

    # 2. Godot render
    godot_exe = os.path.abspath("Godot_v4.7.2-stable_win32_console.exe")
    gd_cmd = [godot_exe, "--path", "godot", "tests/render_single_frame.tscn", "--", "--packet", f"../{acfp_path}", "--output", f"../{gd_png}"]
    gd_res = subprocess.run(gd_cmd, capture_output=True, text=True, timeout=15)
    render_ms = 0.0
    m_time = re.search(r"Time: ([\d\.]+) ms", gd_res.stdout)
    if m_time: render_ms = float(m_time.group(1))

    # 3. Metrics
    im_a = np.array(Image.open(gl_bmp).convert('RGB'), dtype=np.float64)
    im_b = np.array(Image.open(gd_png).convert('RGB'), dtype=np.float64)
    diff = np.abs(im_a - im_b)
    diff_max_per_pixel = np.max(diff, axis=-1)
    exact_pct = (np.sum(diff_max_per_pixel == 0) / (640 * 480)) * 100.0
    max_delta = int(np.max(diff))
    mse = np.mean((im_a - im_b) ** 2)
    psnr = float('inf') if mse == 0 else 10.0 * np.log10((255.0 ** 2) / mse)
    ssim_val = (channel_ssim(im_a[:,:,0], im_b[:,:,0]) +
                channel_ssim(im_a[:,:,1], im_b[:,:,1]) +
                channel_ssim(im_a[:,:,2], im_b[:,:,2])) / 3.0

    # Save diff
    subprocess.run(["python", "tools/pixel_diff.py", gl_bmp, gd_png, "-o", diff_png], capture_output=True)

    return {
        "name": name,
        "packet": os.path.basename(acfp_path),
        "draws": draws,
        "render_ms": render_ms,
        "exact_pct": exact_pct,
        "max_delta": max_delta,
        "psnr": psnr,
        "ssim": ssim_val
    }

if __name__ == "__main__":
    idx = int(sys.argv[1]) if len(sys.argv) > 1 else -1
    if idx >= 0:
        name, path = SCENES[idx]
        res = eval_one(name, path)
        psnr_str = f"{res['psnr']:.2f} dB" if res['psnr'] < 1000 else "inf dB"
        print(f"RESULT|{res['name']}|{res['packet']}|{res['draws']}|{res['render_ms']:.2f}|{res['exact_pct']:.2f}|{res['max_delta']}|{res['ssim']:.6f}|{psnr_str}")
