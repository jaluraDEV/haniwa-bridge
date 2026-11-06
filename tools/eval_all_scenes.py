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

def generate_heatmap(diff_max_per_pixel, path):
    h, w = diff_max_per_pixel.shape
    heatmap = np.zeros((h, w, 3), dtype=np.uint8)
    
    # 0 = Black [0, 0, 0] (Identical)
    # 1..4 = Cyan [0, 180, 180] (Imperceptible LSB noise)
    mask_1_4 = (diff_max_per_pixel >= 1) & (diff_max_per_pixel <= 4)
    heatmap[mask_1_4] = [0, 180, 180]
    
    # 5..20 = Yellow/Orange [255, 180, 0] (Sub-pixel rasterization edge)
    mask_5_20 = (diff_max_per_pixel >= 5) & (diff_max_per_pixel <= 20)
    heatmap[mask_5_20] = [255, 180, 0]
    
    # > 20 = Red [255, 30, 30] (Major divergence)
    mask_gt20 = diff_max_per_pixel > 20
    heatmap[mask_gt20] = [255, 30, 30]
    
    Image.fromarray(heatmap).save(path)

def compute_metrics(im_a_path, im_b_path, heatmap_path=None):
    im_a = np.array(Image.open(im_a_path).convert('RGB'), dtype=np.float64)
    im_b = np.array(Image.open(im_b_path).convert('RGB'), dtype=np.float64)

    total_pixels = im_a.shape[0] * im_a.shape[1]
    diff = np.abs(im_a - im_b)
    diff_max_per_pixel = np.max(diff, axis=-1)

    exact_matches = np.sum(diff_max_per_pixel == 0)
    exact_pct = (exact_matches / total_pixels) * 100.0
    
    d_le4 = np.sum(diff_max_per_pixel <= 4)
    pct_le4 = (d_le4 / total_pixels) * 100.0
    
    d_gt4 = np.sum(diff_max_per_pixel > 4)
    pct_gt4 = (d_gt4 / total_pixels) * 100.0

    max_delta = int(np.max(diff))
    mae = np.mean(diff)
    mse = np.mean((im_a - im_b) ** 2)
    psnr = float('inf') if mse == 0 else 10.0 * np.log10((255.0 ** 2) / mse)

    # Simplified SSIM per channel
    def channel_ssim(c1, c2):
        c1 = c1.flatten()
        c2 = c2.flatten()
        mu1, mu2 = np.mean(c1), np.mean(c2)
        var1, var2 = np.var(c1), np.var(c2)
        cov = np.cov(c1, c2)[0, 1]
        k1, k2, L = 0.01, 0.03, 255.0
        c1_sq, c2_sq = (k1 * L) ** 2, (k2 * L) ** 2
        return ((2 * mu1 * mu2 + c1_sq) * (2 * cov + c2_sq)) / ((mu1 ** 2 + mu2 ** 2 + c1_sq) * (var1 + var2 + c2_sq))

    ssim_val = (channel_ssim(im_a[:,:,0], im_b[:,:,0]) +
                channel_ssim(im_a[:,:,1], im_b[:,:,1]) +
                channel_ssim(im_a[:,:,2], im_b[:,:,2])) / 3.0

    if heatmap_path:
        generate_heatmap(diff_max_per_pixel, heatmap_path)

    return {
        "exact_pct": exact_pct,
        "pct_le4": pct_le4,
        "pct_gt4": pct_gt4,
        "max_delta": max_delta,
        "mae": mae,
        "psnr": psnr,
        "ssim": ssim_val
    }

def main():
    os.makedirs("scratch", exist_ok=True)
    results = []

    start = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    count = int(sys.argv[2]) if len(sys.argv) > 2 else len(SCENES)
    subset = SCENES[start : start + count]

    for name, acfp_path in subset:
        if not os.path.exists(acfp_path):
            print(f"Skipping {name}: {acfp_path} does not exist")
            continue

        base_name = os.path.splitext(os.path.basename(acfp_path))[0]
        gl_bmp = f"scratch/{base_name}_gl.bmp"
        gd_png = f"scratch/{base_name}_gd.png"
        diff_png = f"scratch/{base_name}_diff.png"
        heatmap_png = f"scratch/{base_name}_heatmap.png"

        # 1. Run GL Replay
        gl_cmd = ["tools/acfp_replay.exe", acfp_path, gl_bmp, "port/pc/shaders"]
        gl_res = subprocess.run(gl_cmd, capture_output=True, text=True)
        draws = 0
        m = re.search(r"Executed (\d+) draw calls", gl_res.stdout)
        if m:
            draws = int(m.group(1))

        # 2. Run Godot single frame render
        godot_exe = os.path.abspath("Godot_v4.7.2-stable_win32_console.exe")
        gd_cmd = [
            godot_exe, "--path", "godot", "res://tests/render_single_frame.tscn",
            "--", "--packet", f"../{acfp_path}", "--output", f"../{gd_png}"
        ]
        gd_res = subprocess.run(gd_cmd, capture_output=True, text=True, timeout=20)
        render_ms = 0.0
        m_time = re.search(r"Time: ([\d\.]+) ms", gd_res.stdout)
        if m_time:
            render_ms = float(m_time.group(1))

        # 3. Compute Metrics and generate heatmap
        metrics = compute_metrics(gl_bmp, gd_png, heatmap_png)

        # Save amplified diff image using pixel_diff.py
        subprocess.run(["python", "tools/pixel_diff.py", gl_bmp, gd_png, "-o", diff_png], capture_output=True)

        res_entry = {
            "name": name,
            "packet": os.path.basename(acfp_path),
            "draws": draws,
            "render_ms": render_ms,
            "exact_pct": metrics["exact_pct"],
            "pct_le4": metrics["pct_le4"],
            "pct_gt4": metrics["pct_gt4"],
            "max_delta": metrics["max_delta"],
            "mae": metrics["mae"],
            "psnr": metrics["psnr"],
            "ssim": metrics["ssim"]
        }
        results.append(res_entry)

        psnr_str = f"{metrics['psnr']:.2f} dB" if metrics['psnr'] < 1000 else "inf"
        print(f"| {name:<22} | {draws:>4} | {render_ms:>6.2f} ms | {metrics['exact_pct']:>7.2f}% | <=4: {metrics['pct_le4']:>6.2f}% | >4: {metrics['pct_gt4']:>5.2f}% | Max: {metrics['max_delta']:>3} | SSIM: {metrics['ssim']:>8.6f} |")

    print("\n\n=== FULL MARKDOWN TABLE ===")
    print("| Szene | Datei | Draws | Render-Zeit | Exakt % | Delta <= 4 % | Delta > 4 % | Max Delta | SSIM | PSNR |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    for r in results:
        psnr_str = f"{r['psnr']:.2f} dB" if r['psnr'] < 1000 else "inf dB"
        print(f"| **{r['name']}** | `{r['packet']}` | {r['draws']} | {r['render_ms']:.2f} ms | {r['exact_pct']:.2f} % | {r['pct_le4']:.2f} % | {r['pct_gt4']:.2f} % | {r['max_delta']} / 255 | **{r['ssim']:.6f}** | {psnr_str} |")

if __name__ == "__main__":
    main()
