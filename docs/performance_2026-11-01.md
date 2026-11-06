# Phase 3b: Audio and Frame Pacing Correction (2026-11-01)

## Identified Root Causes

1. The DAC generates 560 stereo frames at 32 kHz per synthesis step, corresponding to 17.5 ms. A mandatory synthesis step per 60 Hz game tick produces 33,600 rather than 32,000 stereo frames per second. Additional catch-up logic accelerated buffer filling. `AIInitDMA` silently truncated overflowing blocks, hiding this defect from the underrun counter.
2. The legacy benchmark measured only work within `_physics_process`, excluding engine rendering, waiting on VSync, or actual frame intervals. Adding `tick_ms + render_ms` in the overlay additionally compounded work executing in parallel. The presumed village test had `scene_override=-1`, zero input, and therefore ran in the title sequence loop.
3. Cache eviction repeatedly iterated through every instance for each stale mesh/material. This search is redundant: all active slots were already bound to current-frame resources, and all inactive slots decoupled.
4. Frame preparation inside the physics callback executed multiple times during physics tick catch-up. Only the final rendered frame was actually presented.

## Implemented Changes

- `pc_audio_service_tick()` produces audio only up to the buffer target when an audio device is active; without an active device, a deterministic single synthesis step per tick is preserved. Synthesis remains isolated on the game worker thread without introducing concurrent access to game state. Target buffer depth remains 17,920 interleaved samples (280 ms).
- Dropped samples are counted separately and queried by the bridge. Removed `printf` calls from the time-critical SDL callback. Ring buffer deltas are computed unsigned to cleanly cross the signed 32-bit boundary.
- The standalone producer now reaches the prefill threshold; previously its target (4,480) sat below the trigger threshold (17,920), which could leave playback permanently stalled at startup.
- Game ticks remain locked at 60 Hz. `_process` processes only the single latest complete packet; during catch-up, superseded intermediate frames are dropped without dropping game ticks.
- Redundant eviction scans were eliminated; unchanged mesh/material bindings are preserved without re-assignment. Statically typed local variables prevent dynamic dispatch overhead during packet and vertex decoding.
- The benchmark harness operates in the genuine main scene. Measurements separately track CPU frame preparation, time intervals between frames, and `RenderingServer.frame_post_draw`. The latter is an engine notification, **not a hardware monitor scanout measurement**.
- 60 FPS cap with VSync disabled by default. On the test machine, visible A/B testing with VSync enabled produced 70 frame intervals > 20 ms (vs. 0 with VSync off). Without VSync, screen tearing may occur; the setting remains configurable in `godot/project.godot`.
  Reference: [Godot Documentation on Jitter and VSync](https://docs.godotengine.org/en/latest/tutorials/rendering/jitter_stutter.html).

## Verification & Metrics

Host: Godot 4.7.2 x86_32, Forward+, RTX 4060 Laptop GPU, reported 60 Hz display.
All accompanying JSON and text files contain pure metrics with zero game assets.

### Audio

`tools/test_audio_clock.sh` compiles an asset-free test against the real SDL backend. A synthetic, continuous PCM waveform is verified for sample continuity over 120 simulated seconds at 60 Hz production and 32 kHz consumption. The corrected loop also handles periodic 100 ms game thread pauses.

| Pipeline | Dropped Samples | Underruns | Discrepant Output Samples |
|---|---:|---:|---:|
| Legacy mandatory synthesis + catch-up | 338,240 | 0 | 6,694,912 |
| Consumption-regulated production | 0 | 0 | 0 |

Evidence: [audio_clock.txt](measurements/2026-11-01/audio_clock.txt).
Discrepant sample counts track phase drift across the entire waveform following a drop, not just the isolated missing samples.

### Visible Title Sequence (1,800 Frames)

The first 300 frames are excluded for boot/shader warm-up; audio metrics are recorded from start. 187–290 draw calls, 1,500 measured frame intervals.

| Metric | 60 FPS Cap, VSync Off | 60 FPS Cap, VSync On |
|---|---:|---:|
| Frame Interval p50 | 16.666 ms | 16.660 ms |
| Frame Interval p95 | 16.739 ms | 19.717 ms |
| Frame Interval p99 | 17.556 ms | 22.102 ms |
| Max Frame Interval | 19.165 ms | 41.129 ms |
| Frame Intervals > 20 ms | 0 | 70 |
| CPU Frame Prep p50 / p99 | 9.017 / 11.518 ms | 9.088 / 11.563 ms |
| Post-Draw Interval p99 | 19.528 ms | 22.164 ms |
| Audio Drops / Underruns | 0 / 0 | 0 / 0 |

Evidence: [Title](measurements/2026-11-01/title_60fps.json),
[VSync Comparison](measurements/2026-11-01/title_vsync_comparison.json).
Buffer held steady between 15,872 and 19,008 samples (~248–297 ms).
The initial boot phase includes shader compilation and resource initialization spikes.

An obscured background control window performed significantly slower (3,600 frames in 80.33 s; p99 34.96 ms). This demonstrates window occlusion effects in this environment without isolating specific OS or driver mechanisms.
Evidence: [Background Control](measurements/2026-11-01/hidden_window_control.json).

### Renderer Parity & Resource Lifetime

`test_renderer_regression.tscn` compares the previous and updated renderer in separate viewports across 3 iterations of 13 local capture scenes. New resource IDs with identical geometry force cache eviction; varying draw call counts validate detachment of inactive instances.

**39/39 frames byte-identical, 1,811 mesh evictions, 0 engine errors.**
Evidence: [renderer_regression.txt](measurements/2026-11-01/renderer_regression.txt).
This demonstrates that optimizations preserve existing rendering output, but does not imply resolution of all earlier Forward+ deviations from original hardware.

## Reproduction Steps

From the project root with user-provided ISO and local captures:

```powershell
& "$env:USERPROFILE/msys64/usr/bin/bash.exe" tools/build_bridge.sh
& "$env:USERPROFILE/msys64/usr/bin/bash.exe" tools/test_audio_clock.sh
.\Godot_v4.7.2-stable_win32_console.exe --path godot -- --benchmark-frames 1800 --benchmark-output res://../scratch/title.json
.\Godot_v4.7.2-stable_win32_console.exe --path godot res://tests/test_village_5min.tscn -- --benchmark-output res://../scratch/village.json
```

Keep the game window visible for performance profiling. The village test explicitly loads scene 7; `--frames N` shortens duration. Game state is not written to disk. The benchmark exits with code 1 upon any audio loss or underrun.

For pixel regression testing, export a previous renderer as GDScript, rename `class_name ACFPRenderer` to `class_name ACFPBaselineRenderer`, and execute `test_renderer_regression.tscn -- --baseline <absolute script path>`.

## Remaining Constraints

- No continuous 30-minute audio validation or exhaustive interactive test covering all scenes/save states. Phase 4 or Gate 6 completion cannot be inferred from this test alone.
- Audio latency is intentionally budgeted around 280 ms; lowering this requires dedicated testing with cold shader caches and scene transitions.
- The `shutdown_game()` API is unstable when forcing village startup without a save file (crash inside existing scene destructor). Normal application exit stops/joins the worker and releases rendering resources without invoking this newly introduced destructor path; process termination cleans up the port as before.

### Conclusion: 5-Minute Continuous Village Run

18,000 frames in **300.154 s** (~59.97 FPS including startup), 17,700 sampled frames post warm-up. Frame intervals p50/p95/p99 **16.666/16.735/17.104 ms**; 10 intervals > 20 ms, maximum 46.914 ms. Post-draw p99 18.054 ms.
CPU frame prep p50/p99 2.080/3.347 ms; 0–78 draw calls, 58.07 MB Godot static memory. **0 audio drops, 0 underruns**, buffer 15,872–19,008 samples.
Zero engine errors on stderr. Forced village startup without a save periodically resets via `toNextLand: l_keepSave not set` and `trademark_init`; this test proves 5 minutes of stability including these transitions rather than an uninterrupted gameplay session. Specific scene transitions continue to generate minor spikes.
Evidence: [village_start_5min.json](measurements/2026-11-01/village_start_5min.json).
