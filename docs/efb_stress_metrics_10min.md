# EFB Reliability & Host Pacing Stress Test (10 Minutes)

**Date**: 2026-11-03T14:43:48

**Duration**: 600.01 s (10.00 min)

## 1. Frame and Tick Differentiation

| Metric | Absolute Value | Frequency | Description |
|---|---:|---:|---|
| **Host Simulation Ticks** | 36001 | **60.00 Hz** | 32-Bit Host Tick Count (frame_id delta) |
| **Godot Polling Iterations** | 35634 | **59.39 Hz** | Main thread `_process()` calls |
| **Received Packets** | 35187 | 58.64 Hz | Successfully polled from SHM (`poll_frame() != empty`) |
| **Artificially Dropped Frames** | 11729 | **33.33 %** | Exactly every 3rd received frame dropped |
| **Rendered Frames** | 23458 | 39.10 Hz | Frames submitted to Forward+ renderer |

## 2. EFB Copy Reliability

| Metric | Value |
|---|---:|
| Inventory Cycles (Open / Close) | 183 |
| EFB Copies Captured & Acknowledged | 183 |
| Duplicate Retransmissions Processed | 92 |
| **Lost EFB Copies** | **0** |

### Evaluation & Result
> [!IMPORTANT]
> **PASS**: 0 lost EFB copies over 10 minutes under 33.3% artificial frame dropping. All sequence numbers were retransmitted without gaps by the host and acknowledged by Godot.
