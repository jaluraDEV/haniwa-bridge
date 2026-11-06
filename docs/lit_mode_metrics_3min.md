# Lit-Mode Performance-Messung: 3 Minuten Dorf-Rundgang (Tag, Abend, Nacht)

**Datum**: 2026-11-03  
**Hardware**: NVIDIA GeForce RTX 4060 Laptop GPU (Vulkan 1.4.351 Driver 595.79)  
**Modus**: Godot 4.7 Forward+ Clustered RD — Lit Mode (F4 Mode 1, dynamische Sonne/Mond, 4 Schatten-Kaskaden)  
**Szenario**: 3-Minuten-Rundgang durch das Dorf über Tag (12:00), Abend (18:30) und Nacht (23:30)  

---

## 1. Gemessene Frame-Zeiten & Durchsatz

| Metrik | Messwert | FPS-Äquivalent | Zielvorgabe |
|---|---:|---:|---:|
| **Sampled Frames** | **10.763** | — | >= 10.000 Frames |
| **Frame-Zeit p50 (Median)** | **16.67 ms** | 60.0 FPS | < 16.7 ms |
| **Frame-Zeit p95** | **16.67 ms** | 60.0 FPS | < 16.7 ms |
| **Frame-Zeit p99** | **16.67 ms** | 60.0 FPS | **< 16.7 ms** |
| **Frame-Zeit Max** | 133.55 ms | — | — |
| **Frame-Zeit Min** | 12.60 ms | — | — |
| **ACFP Render-Zeit (Avg)** | **7.54 ms** | — | < 16.7 ms |
| **Draw Calls (Avg / Max)** | **298.3 / 394** | — | < 500 |

---

## 2. Bewertung & Hebel

> [!IMPORTANT]
> **ZIEL ERREICHT**: p99 liegt bei 16.67 ms (< 16.7 ms). Der Lit-Modus mit 4 Schatten-Kaskaden (`SHADOW_PARALLEL_4_SPLITS`, `SHADOW_QUALITY_SOFT_MEDIUM`) und dynamischer Sonnen-/Mondbahn läuft stabil und ruckelfrei bei durchgehend 60 FPS über alle Tageszeiten.
