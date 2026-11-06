#!/usr/bin/env python3
"""
tools/pixel_diff.py - Image comparison tool for ACGC + Godot Render-Capture

Compares two images (OpenGL original vs. Replay/Godot renderer), computes exact
metrics (MAE, RMSE, PSNR, SSIM, exact match percentage), and outputs an
amplified difference image.
"""

import sys
import os
import argparse
import numpy as np
from PIL import Image

def compute_ssim(img1, img2):
    """Compute mean Structural Similarity Index (SSIM) on float images [0, 1]."""
    C1 = (0.01 * 255) ** 2
    C2 = (0.03 * 255) ** 2

    img1 = img1.astype(np.float64)
    img2 = img2.astype(np.float64)

    mu1 = np.mean(img1)
    mu2 = np.mean(img2)
    sigma1_sq = np.var(img1)
    sigma2_sq = np.var(img2)
    sigma12 = np.mean((img1 - mu1) * (img2 - mu2))

    ssim = ((2 * mu1 * mu2 + C1) * (2 * sigma12 + C2)) / \
           ((mu1**2 + mu2**2 + C1) * (sigma1_sq + sigma2_sq + C2))
    return float(ssim)

def compare_images(path_a, path_b, diff_path=None, amplify=10):
    if not os.path.exists(path_a):
        print(f"[Error] Image A not found: {path_a}")
        return False
    if not os.path.exists(path_b):
        print(f"[Error] Image B not found: {path_b}")
        return False

    im_a = Image.open(path_a).convert("RGBA")
    im_b = Image.open(path_b).convert("RGBA")

    if im_a.size != im_b.size:
        print(f"[Error] Size mismatch: Image A is {im_a.size}, Image B is {im_b.size}")
        return False

    w, h = im_a.size
    total_pixels = w * h

    arr_a = np.array(im_a, dtype=np.int32)
    arr_b = np.array(im_b, dtype=np.int32)

    # Compare RGB channels (ignore alpha if 255)
    rgb_a = arr_a[:, :, :3]
    rgb_b = arr_b[:, :, :3]

    diff_rgb = np.abs(rgb_a - rgb_b)
    diff_max_per_pixel = np.max(diff_rgb, axis=2)

    exact_matches = int(np.sum(diff_max_per_pixel == 0))
    match_pct = (exact_matches / total_pixels) * 100.0

    max_delta = int(np.max(diff_rgb))
    mae = float(np.mean(diff_rgb))
    mse = float(np.mean((rgb_a - rgb_b) ** 2))
    rmse = float(np.sqrt(mse))

    if mse == 0:
        psnr = float('inf')
    else:
        psnr = float(20 * np.log10(255.0 / rmse))

    ssim_val = compute_ssim(rgb_a, rgb_b)

    # Delta histogram
    d1 = int(np.sum(diff_max_per_pixel == 1))
    d2_5 = int(np.sum((diff_max_per_pixel >= 2) & (diff_max_per_pixel <= 5)))
    d_gt5 = int(np.sum(diff_max_per_pixel > 5))

    print(f"=== Pixel Comparison Report ===")
    print(f"Image A: {path_a}")
    print(f"Image B: {path_b}")
    print(f"Resolution: {w}x{h} ({total_pixels} pixels)")
    print(f"Exact Matches: {exact_matches}/{total_pixels} ({match_pct:.4f}%)")
    print(f"Max Delta:     {max_delta} / 255")
    print(f"MAE:           {mae:.4f}")
    print(f"RMSE:          {rmse:.4f}")
    print(f"PSNR:          {psnr:.2f} dB")
    print(f"SSIM:          {ssim_val:.6f}")
    print(f"Mismatches:")
    print(f"  Delta = 1:   {d1} ({d1/total_pixels*100.0:.3f}%)")
    print(f"  Delta 2..5:  {d2_5} ({d2_5/total_pixels*100.0:.3f}%)")
    print(f"  Delta > 5:   {d_gt5} ({d_gt5/total_pixels*100.0:.3f}%)")

    # Generate amplified visual diff
    if diff_path:
        os.makedirs(os.path.dirname(os.path.abspath(diff_path)), exist_ok=True)
        # Scale differences by amplify factor, highlight mismatches
        diff_vis = np.zeros((h, w, 4), dtype=np.uint8)
        # Red channel shows difference amplified
        amplified = np.clip(diff_max_per_pixel * amplify, 0, 255).astype(np.uint8)
        diff_vis[:, :, 0] = amplified
        # Blue channel shows slight reference background for spatial context
        diff_vis[:, :, 2] = (rgb_a[:, :, 0] // 4).astype(np.uint8)
        diff_vis[:, :, 3] = 255

        # If mismatch, also light up green slightly
        diff_vis[diff_max_per_pixel > 0, 1] = 64

        diff_img = Image.fromarray(diff_vis, "RGBA")
        diff_img.save(diff_path)
        print(f"Diff image saved: {diff_path} (amplification: {amplify}x)")

    return True

def main():
    parser = argparse.ArgumentParser(description="ACGC Pixel Diff Tool")
    parser.add_argument("image_a", help="Path to original image")
    parser.add_argument("image_b", help="Path to replay/comparison image")
    parser.add_argument("-o", "--output-diff", help="Path to output diff PNG", default=None)
    parser.add_argument("-a", "--amplify", type=int, default=10, help="Difference amplification factor")

    args = parser.parse_args()
    success = compare_images(args.image_a, args.image_b, args.output_diff, args.amplify)
    sys.exit(0 if success else 1)

if __name__ == "__main__":
    main()
