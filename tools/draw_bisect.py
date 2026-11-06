#!/usr/bin/env python3
"""
tools/draw_bisect.py - Draw-call bisect & divergence analysis tool
Compares Godot rendering against OpenGL reference replay up to Draw K,
finds the first divergent draw call, and dumps its complete graphics state.
"""

import sys
import os
import struct
import argparse
import subprocess
import numpy as np
from PIL import Image

GODOT_BIN = os.path.abspath("Godot_v4.7.2-stable_win32_console.exe")
REPLAY_BIN = os.path.abspath("tools/acfp_replay.exe")

ZFUNCS = ["NEVER", "LESS", "EQUAL", "LEQUAL", "GREATER", "NOTEQUAL", "GEQUAL", "ALWAYS"]
PASSES = ["OPAQUE", "TRANSPARENT", "UI"]
CULLS = ["NONE", "FRONT", "BACK", "ALL"]
BLENDS = ["NONE", "BLEND_MIX", "LOGIC", "BLEND_SUB"]
WRAPS = ["CLAMP", "REPEAT", "MIRROR"]

def parse_packet_draws(packet_path):
    with open(packet_path, 'rb') as f:
        data = f.read()

    hdr_fmt = '<4sIIIIfffffIIIIIIII'
    hdr_size = struct.calcsize(hdr_fmt)
    fields = struct.unpack(hdr_fmt, data[:hdr_size])
    toff, tcnt, voff, vcnt_tbl, coff, csz = fields[11], fields[12], fields[13], fields[14], fields[15], fields[16]

    vbo_hdr_size = 28
    vbo_hdr_array_size = vcnt_tbl * vbo_hdr_size
    vbos = []
    v_cur = voff
    for i in range(vcnt_tbl):
        vid, vhash, vcnt, stride, doff, dsz = struct.unpack('<IQIIII', data[v_cur:v_cur+28])
        v_cur += 28
        vbos.append({'id': vid, 'hash': vhash, 'count': vcnt, 'stride': stride})

    cursor = coff
    draws = []
    cur_state = {
        'z_test': 1, 'z_func': 3, 'z_write': 1, 'cull': 0, 'blend': 0,
        'alpha_ctrl': (7, 0, 7), 'alpha_refs': (0, 0),
        'scissor': (0, 0, 0, 0),
        'num_tev_stages': 1,
        'tev_stages': [None, None, None],
        'textures': [(-1, 0, 0, 1), (-1, 0, 0, 1), (-1, 0, 0, 1)], # id, wrap_s, wrap_t, filter
        'transforms': None,
        'projection': None
    }

    while cursor + 4 <= coff + csz:
        op, sz = struct.unpack('<HH', data[cursor:cursor+4])
        payload = data[cursor+4 : cursor+4+sz]
        cursor += 4 + sz
        if op == 0xFFFF:
            break
        elif op == 0x0001: # VP_SCISSOR
            if len(payload) >= 40:
                vp_w, vp_h = struct.unpack('<ff', payload[8:16])
                sc_l, sc_t, sc_w, sc_h = struct.unpack('<iiii', payload[24:40])
                cur_state['scissor'] = (sc_l, sc_t, sc_w, sc_h)
        elif op == 0x0004: # DEPTH_BLEND
            z_test, z_func, z_write, cull, blend = struct.unpack('<BBBBB', payload[:5])
            cur_state['z_test'] = z_test
            cur_state['z_func'] = z_func
            cur_state['z_write'] = z_write
            cur_state['cull'] = cull
            cur_state['blend'] = blend
        elif op == 0x0005: # ALPHA_TEST
            c0, ref0, op_c, c1, ref1 = struct.unpack('<BBBBB', payload[:5])
            cur_state['alpha_ctrl'] = (c0, op_c, c1)
            cur_state['alpha_refs'] = (ref0, ref1)
        elif op == 0x0009: # TEV_STAGE
            stg = payload[0]
            if stg < 3:
                cur_state['tev_stages'][stg] = dict(
                    c_in=struct.unpack('<BBBB', payload[1:5]),
                    a_in=struct.unpack('<BBBB', payload[5:9]),
                    c_op=payload[9], a_op=payload[14],
                    bsc=struct.unpack('<BBBB', bytes([payload[10], payload[11], payload[15], payload[16]])),
                    out=struct.unpack('<BBBB', bytes([payload[12], payload[17], payload[13], payload[18]])),
                    tc_src=payload[19] if len(payload) > 19 else 0
                )
        elif op == 0x000A: # TEV_REGISTERS
            cur_state['num_tev_stages'] = struct.unpack('<I', payload[:4])[0]
        elif op == 0x000B: # BIND_TEXTURE
            stg, tid, ws, wt = struct.unpack('<IIBB', payload[:10])
            flt = payload[10] if len(payload) > 10 else 1
            if stg < 3:
                cur_state['textures'][stg] = (tid, ws, wt, flt)
        elif op == 0x000D: # DRAW
            prim, ptype, vboid, voff, vcnt = struct.unpack('<HHIII', payload[:16])
            draw_info = {
                'index': len(draws),
                'prim': prim,
                'pass': ptype,
                'vbo_id': vboid,
                'vbo_offset': voff,
                'vertex_count': vcnt,
                'state': {
                    'z_test': cur_state['z_test'],
                    'z_func': cur_state['z_func'],
                    'z_write': cur_state['z_write'],
                    'cull': cur_state['cull'],
                    'blend': cur_state['blend'],
                    'alpha_ctrl': cur_state['alpha_ctrl'],
                    'alpha_refs': cur_state['alpha_refs'],
                    'scissor': cur_state['scissor'],
                    'num_tev_stages': cur_state['num_tev_stages'],
                    'tev_stages': list(cur_state['tev_stages']),
                    'textures': list(cur_state['textures'])
                }
            }
            draws.append(draw_info)
    return draws

def compute_metrics(im_a, im_b):
    arr_a = np.array(im_a.convert("RGB"), dtype=np.int32)
    arr_b = np.array(im_b.convert("RGB"), dtype=np.int32)
    diff = np.abs(arr_a - arr_b)
    diff_max = np.max(diff, axis=2)
    total = arr_a.shape[0] * arr_a.shape[1]
    exact = int(np.sum(diff_max == 0))
    exact_pct = (exact / total) * 100.0
    max_delta = int(np.max(diff))
    mae = float(np.mean(diff))
    mse = float(np.mean((arr_a - arr_b) ** 2))
    rmse = float(np.sqrt(mse))
    psnr = float('inf') if mse == 0 else float(20 * np.log10(255.0 / rmse))

    # SSIM
    c1 = (0.01 * 255) ** 2
    c2 = (0.03 * 255) ** 2
    f_a = arr_a.astype(np.float64)
    f_b = arr_b.astype(np.float64)
    mu1 = np.mean(f_a)
    mu2 = np.mean(f_b)
    sigma1_sq = np.var(f_a)
    sigma2_sq = np.var(f_b)
    sigma12 = np.mean((f_a - mu1) * (f_b - mu2))
    ssim = ((2 * mu1 * mu2 + c1) * (2 * sigma12 + c2)) / ((mu1**2 + mu2**2 + c1) * (sigma1_sq + sigma2_sq + c2))

    return {
        'exact_pct': exact_pct,
        'exact_count': exact,
        'total': total,
        'max_delta': max_delta,
        'mae': mae,
        'rmse': rmse,
        'psnr': psnr,
        'ssim': float(ssim),
        'diff_max': diff_max
    }

def render_draw(packet_path, k, debug_color=False):
    os.makedirs("captures/bisect_tmp", exist_ok=True)
    replay_out = os.path.abspath(f"captures/bisect_tmp/rep_{k}.bmp")
    godot_out = os.path.abspath(f"captures/bisect_tmp/god_{k}.png")

    # 1. Render Replay
    replay_args = [REPLAY_BIN, packet_path, replay_out, "port/pc/shaders", "--max-draws", str(k)]
    if debug_color:
        replay_args.append("--debug-color")
    res_rep = subprocess.run(replay_args, capture_output=True, text=True, timeout=15)
    if res_rep.returncode != 0:
        print(f"[Error] Replay failed for k={k}: {res_rep.stderr}")
        return None

    # 2. Render Godot
    # Convert paths to relative to godot/ or absolute
    rel_packet = os.path.relpath(packet_path, "godot")
    rel_godot_out = os.path.relpath(godot_out, "godot")
    godot_cmd = [
        GODOT_BIN, "--path", "godot",
        "res://tests/render_single_frame.tscn", "--",
        "--packet", rel_packet,
        "--output", rel_godot_out,
        "--max-draws", str(k)
    ]
    if debug_color:
        godot_cmd.append("--debug-color")

    res_god = subprocess.run(godot_cmd, capture_output=True, text=True, timeout=15)
    if not os.path.exists(godot_out):
        print(f"[Error] Godot failed to write output for k={k}: {res_god.stdout} {res_god.stderr}")
        return None

    im_rep = Image.open(replay_out)
    im_god = Image.open(godot_out)
    metrics = compute_metrics(im_rep, im_god)
    return metrics

def print_draw_state(d):
    idx = d['index']
    ptype = d['pass']
    pname = PASSES[ptype] if ptype < len(PASSES) else str(ptype)
    st = d['state']
    zfunc = ZFUNCS[st['z_func']] if st['z_func'] < len(ZFUNCS) else str(st['z_func'])
    cull = CULLS[st['cull']] if st['cull'] < len(CULLS) else str(st['cull'])
    blend = BLENDS[st['blend']] if st['blend'] < len(BLENDS) else str(st['blend'])

    print(f"\n================================================================================")
    print(f"  STATE DUMP FOR FIRST DIVERGING DRAW CALL: Draw #{idx}")
    print(f"================================================================================")
    print(f"  * Pipeline Pass:    {pname} ({ptype})")
    print(f"  * Primitive Type:   0x{d['prim']:02X} (vertex_count: {d['vertex_count']}, VBO #{d['vbo_id']}, offset {d['vbo_offset']})")
    print(f"  * Depth / Z-Buffer: z_test={st['z_test']}, z_write={st['z_write']}, z_func={zfunc} ({st['z_func']})")
    print(f"  * Rasterizer:       cull_mode={cull} ({st['cull']}), blend_mode={blend} ({st['blend']})")
    print(f"  * Scissor:          left={st['scissor'][0]}, top={st['scissor'][1]}, w={st['scissor'][2]}, h={st['scissor'][3]}")
    print(f"  * Alpha Compare:    ctrl={st['alpha_ctrl']}, refs={st['alpha_refs']}")
    print(f"  * TEV Stages:       {st['num_tev_stages']} active stage(s)")
    for s_idx in range(st['num_tev_stages']):
        stg = st['tev_stages'][s_idx]
        if stg:
            print(f"      Stage {s_idx}: color_in={stg['c_in']}, alpha_in={stg['a_in']}, op=(c:{stg['c_op']}, a:{stg['a_op']}), bsc={stg['bsc']}, tc_src={stg['tc_src']}")
    print(f"  * Textures:")
    for s_idx in range(3):
        tid, ws, wt, flt = st['textures'][s_idx]
        ws_str = WRAPS[ws] if ws < len(WRAPS) else str(ws)
        wt_str = WRAPS[wt] if wt < len(WRAPS) else str(wt)
        if tid != 4294967295 and tid >= 0:
            print(f"      Stage {s_idx}: Texture #{tid} (wrap_s: {ws_str}, wrap_t: {wt_str}, filter: {flt})")
        else:
            print(f"      Stage {s_idx}: NONE")
    print(f"================================================================================\n")

def main():
    parser = argparse.ArgumentParser(description="ACGC Draw-Bisect & State Inspector")
    parser.add_argument("packet", help="Path to .acfp packet file")
    parser.add_argument("--tolerance", type=float, default=98.0, help="Min exact match pixel percent (default: 98.0)")
    parser.add_argument("--tolerance-ssim", type=float, default=0.99, help="Min SSIM (default: 0.99)")
    parser.add_argument("--debug-color", action="store_true", help="Enable index-based debug coloring")
    parser.add_argument("--draw", type=int, default=-1, help="Test only a specific draw index K")
    parser.add_argument("--scan-all", action="store_true", help="Scan every draw sequentially")
    args = parser.parse_args()

    draws = parse_packet_draws(args.packet)
    total_draws = len(draws)
    print(f"[Bisect] Loaded packet '{args.packet}' with {total_draws} draw calls.")

    if total_draws == 0:
        print("[Bisect] No draw calls in packet.")
        return

    if args.draw >= 0:
        k = args.draw
        print(f"[Bisect] Inspecting single draw call #{k}...")
        m = render_draw(args.packet, k, args.debug_color)
        if m:
            print(f"Draw #{k}: Exact={m['exact_pct']:.2f}% | SSIM={m['ssim']:.4f} | MaxDelta={m['max_delta']} | MAE={m['mae']:.2f}")
            print_draw_state(draws[k - 1] if k > 0 and k <= len(draws) else draws[0])
        return

    # Check Draw 1 first
    print(f"[Bisect] Checking Draw #1...")
    m1 = render_draw(args.packet, 1, args.debug_color)
    if not m1:
        print("[Bisect] Failed to render Draw #1.")
        return
    print(f"Draw #1: Exact={m1['exact_pct']:.2f}% | SSIM={m1['ssim']:.4f} | MaxDelta={m1['max_delta']}")

    first_divergent = None

    if m1['exact_pct'] < args.tolerance or m1['ssim'] < args.tolerance_ssim:
        first_divergent = 0
    else:
        # Check Final Draw
        print(f"[Bisect] Checking Final Draw #{total_draws}...")
        m_final = render_draw(args.packet, total_draws, args.debug_color)
        if m_final and m_final['exact_pct'] >= args.tolerance and m_final['ssim'] >= args.tolerance_ssim:
            print(f"[Bisect] Full frame PASSED! Exact={m_final['exact_pct']:.2f}%, SSIM={m_final['ssim']:.4f}")
            return

        # Binary search for first divergent draw call
        low = 1
        high = total_draws
        while low < high:
            mid = (low + high) // 2
            print(f"[Bisect] Testing range [{low}..{high}], probing Draw #{mid}...")
            m = render_draw(args.packet, mid, args.debug_color)
            if not m:
                high = mid
                continue
            print(f"  Draw #{mid}: Exact={m['exact_pct']:.2f}% | SSIM={m['ssim']:.4f} | MaxDelta={m['max_delta']}")
            if m['exact_pct'] < args.tolerance or m['ssim'] < args.tolerance_ssim:
                # Mid already diverges, look earlier
                high = mid
            else:
                # Mid still matches, divergence is later
                low = mid + 1
        first_divergent = low - 1 # 0-indexed draw call that caused the divergence

    if first_divergent is not None and first_divergent < total_draws:
        div_draw = draws[first_divergent]
        print(f"\n>>> FIRST DIVERGING DRAW CALL FOUND AT INDEX #{first_divergent} (1-based: Draw #{first_divergent + 1}) <<<")
        print_draw_state(div_draw)

        # Save amplified visual diff for this draw
        k = first_divergent + 1
        replay_out = f"captures/bisect_tmp/rep_{k}.bmp"
        godot_out = f"captures/bisect_tmp/god_{k}.png"
        diff_out = f"captures/bisect_divergence_draw_{k}.png"
        if os.path.exists(replay_out) and os.path.exists(godot_out):
            im_rep = Image.open(replay_out).convert("RGB")
            im_god = Image.open(godot_out).convert("RGB")
            m = compute_metrics(im_rep, im_god)
            diff_vis = np.zeros((480, 640, 4), dtype=np.uint8)
            diff_vis[:, :, 0] = np.clip(m['diff_max'] * 10, 0, 255).astype(np.uint8)
            diff_vis[:, :, 2] = (np.array(im_rep)[:, :, 0] // 4).astype(np.uint8)
            diff_vis[:, :, 3] = 255
            diff_vis[m['diff_max'] > 0, 1] = 64
            Image.fromarray(diff_vis, "RGBA").save(diff_out)
            print(f"[Bisect] Saved amplified divergence diff image: {diff_out}")

if __name__ == "__main__":
    main()
