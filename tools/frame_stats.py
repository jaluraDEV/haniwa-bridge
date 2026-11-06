#!/usr/bin/env python3
"""
tools/frame_stats.py - Parse and analyze ACFP frame packets for Gate 2 statistics.
Computes:
- Packet size (bytes pro Frame)
- Draw call count
- Texture count, raw uncompressed texture memory
- VBO count, vertex count, raw vertex data memory
- Deduplication / Cache potential
"""

import sys
import os
import struct
import glob

def parse_acfp(filepath):
    with open(filepath, "rb") as f:
        data = f.read()

    if len(data) < 56:
        return None

    # ACFP Header (56 bytes)
    # char magic[4], u32 version, u32 frame_index, u32 tick_count, u32 width, u32 height
    # float clear_color[4], float clear_depth
    # u32 tex_table_offset, u32 tex_table_count
    # u32 vbo_table_offset, u32 vbo_table_count
    # u32 cmd_stream_offset, u32 cmd_stream_size
    magic = data[:4]
    if magic != b"ACFP":
        return None

    version, frame_idx, tick_count, width, height = struct.unpack_from("<5I", data, 4)
    clear_r, clear_g, clear_b, clear_a, clear_d = struct.unpack_from("<5f", data, 24)
    tex_offset, tex_count, vbo_offset, vbo_count, cmd_offset, cmd_size = struct.unpack_from("<6I", data, 44)

    # Texture headers
    # u32 tex_id, u64 hash, u16 width, u16 height, u8 format, u8 mipmaps, u8 reserved[2], u32 data_offset, u32 data_size
    # Size = 4 + 8 + 2 + 2 + 1 + 1 + 2 + 4 + 4 = 28 bytes
    tex_data_bytes = 0
    unique_tex_hashes = set()
    offset = tex_offset
    for _ in range(tex_count):
        if offset + 28 > len(data):
            break
        tid, thash, tw, th, tfmt, tmip, rsv, tdoff, tdsize = struct.unpack_from("<IQ2H2B2s2I", data, offset)
        tex_data_bytes += tdsize
        unique_tex_hashes.add(thash)
        offset += 28

    # VBO headers
    # u32 vbo_id, u64 hash, u32 vertex_count, u32 stride, u32 data_offset, u32 data_size
    # Size = 4 + 8 + 4 + 4 + 4 + 4 = 28 bytes
    vbo_data_bytes = 0
    total_vertices = 0
    unique_vbo_hashes = set()
    offset = vbo_offset
    for _ in range(vbo_count):
        if offset + 28 > len(data):
            break
        vid, vhash, vcount, vstride, vdoff, vdsize = struct.unpack_from("<IQ4I", data, offset)
        vbo_data_bytes += vdsize
        total_vertices += vcount
        unique_vbo_hashes.add(vhash)
        offset += 28

    # Commands
    cmd_ptr = cmd_offset
    draw_calls = 0
    draw_vertices = 0
    vbos_referenced = []
    textures_bound = []
    cmd_counts = {}

    while cmd_ptr + 4 <= cmd_offset + cmd_size and cmd_ptr + 4 <= len(data):
        opcode, psize = struct.unpack_from("<2H", data, cmd_ptr)
        cmd_counts[opcode] = cmd_counts.get(opcode, 0) + 1
        payload = data[cmd_ptr + 4 : cmd_ptr + 4 + psize]
        cmd_ptr += 4 + psize

        if opcode == 0x000D:  # ACFP_CMD_DRAW
            draw_calls += 1
            if len(payload) >= 16:
                prim, pass_t, vbo_id, voff, vcnt = struct.unpack_from("<2H3I", payload)
                draw_vertices += vcnt
                vbos_referenced.append(vbo_id)
        elif opcode == 0x000B:  # ACFP_CMD_BIND_TEXTURE
            if len(payload) >= 8:
                stg, tid = struct.unpack_from("<2I", payload[:8])
                if tid != 0xFFFFFFFF:
                    textures_bound.append(tid)

    return {
        "filepath": filepath,
        "filename": os.path.basename(filepath),
        "frame_index": frame_idx,
        "file_size": len(data),
        "cmd_stream_size": cmd_size,
        "draw_calls": draw_calls,
        "draw_vertices": draw_vertices,
        "tex_count": tex_count,
        "tex_data_bytes": tex_data_bytes,
        "unique_tex_hashes": len(unique_tex_hashes),
        "vbo_count": vbo_count,
        "vbo_data_bytes": vbo_data_bytes,
        "unique_vbo_hashes": len(unique_vbo_hashes),
        "total_vertices": total_vertices,
        "vbos_referenced_count": len(vbos_referenced),
        "textures_bound_count": len(textures_bound),
        "tex_hashes": unique_tex_hashes,
        "vbo_hashes": unique_vbo_hashes,
    }

def print_stats_table(scenes):
    header = f"{'Scene / File':<26} | {'Packet Size':<11} | {'Draws':<6} | {'Verts':<7} | {'Textures':<9} | {'Tex RAM':<10} | {'VBOs':<5} | {'VBO RAM':<9}"
    sep = "=" * len(header)
    print(sep)
    print("GATE 2 RENDER-CAPTURE STATISTIK (docs/frame_packet.md & docs/gx_mapping.md)")
    print(sep)
    print(header)
    print("-" * len(header))
    for s in scenes:
        name = s['filename']
        psize = f"{s['file_size']/1024:.1f} KB"
        draws = f"{s['draw_calls']}"
        verts = f"{s['draw_vertices']}"
        texs = f"{s['tex_count']}"
        tex_ram = f"{s['tex_data_bytes']/1024:.1f} KB"
        vbos = f"{s['vbo_count']}"
        vbo_ram = f"{s['vbo_data_bytes']/1024:.1f} KB"
        print(f"{name:<26} | {psize:<11} | {draws:<6} | {verts:<7} | {texs:<9} | {tex_ram:<10} | {vbos:<5} | {vbo_ram:<9}")
    print(sep)

    print("\n" + "=" * 80)
    print("CACHE-POTENZIAL & DEDUPLIKATIONS-ANALYSE")
    print("=" * 80)

    # 1. Texture Bind Reuse
    for s in scenes:
        binds = s['textures_bound_count']
        unique_t = s['tex_count']
        draws = s['draw_calls']
        reuse_ratio = (binds / unique_t) if unique_t > 0 else 0
        print(f"[{s['filename']:<24}] {draws} Drawcalls, {binds} Texture Binds auf {unique_t} Texturen (Reuse: {reuse_ratio:.2f}x pro Textur)")

    # 2. Inter-frame cache reuse
    print("\nInter-Frame Cache-Wiederverwendung (Geometrie & Texturen):")
    pairs = [
        ("frame_60.acfp", "frame_150.acfp", "Title Screen Demo (Frame 60 -> Frame 150)"),
        ("scene_village_day.acfp", "scene_village_night.acfp", "Dorf Tag -> Nacht"),
        ("scene_village_day.acfp", "scene_fog.acfp", "Dorf Tag -> Nebel/Regen"),
        ("scene_interior.acfp", "scene_house.acfp", "Nook Shop -> Spielerhaus"),
    ]
    scene_map = {s['filename']: s for s in scenes}
    for f1, f2, desc in pairs:
        if f1 in scene_map and f2 in scene_map:
            s1 = scene_map[f1]
            s2 = scene_map[f2]
            common_tex = s1['tex_hashes'].intersection(s2['tex_hashes'])
            all_tex = s1['tex_hashes'].union(s2['tex_hashes'])
            tex_reuse_pct = (len(common_tex) / len(all_tex) * 100.0) if all_tex else 0

            common_vbo = s1['vbo_hashes'].intersection(s2['vbo_hashes'])
            all_vbo = s1['vbo_hashes'].union(s2['vbo_hashes'])
            vbo_reuse_pct = (len(common_vbo) / len(all_vbo) * 100.0) if all_vbo else 0

            print(f"  * {desc:<45}:")
            print(f"      Texturen identisch:  {len(common_tex)}/{len(all_tex)} ({tex_reuse_pct:.1f}%)")
            print(f"      VBOs identisch:      {len(common_vbo)}/{len(all_vbo)} ({vbo_reuse_pct:.1f}%)")
    print("=" * 80)

if __name__ == "__main__":
    files = sys.argv[1:] if len(sys.argv) > 1 else sorted(glob.glob("captures/*.acfp"))
    scenes = []
    for f in files:
        st = parse_acfp(f)
        if st:
            scenes.append(st)
    print_stats_table(scenes)
