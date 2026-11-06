# EFB Reliability & Host Pacing Stress Test (10 Minuten)

**Datum**: 2026-11-03T14:43:48

**Dauer**: 600.01 s (10.00 min)

## 1. Frame- und Takt-Differenzierung

| Metrik | Absoluter Wert | Frequenz | Beschreibung |
|---|---:|---:|---|
| **Host Simulationstakte** | 36001 | **60.00 Hz** | 32-Bit Host Tick-Count (frame_id Delta) |
| **Godot Polling-Iterationen** | 35634 | **59.39 Hz** | Main-Thread `_process()` Aufrufe |
| **Empfangene Pakete** | 35187 | 58.64 Hz | Erfolgreich aus SHM gepollt (`poll_frame() != empty`) |
| **Künstlich verworfene Frames** | 11729 | **33.33 %** | Exakt jeder 3. empfangene Frame übersprungen |
| **Gerenderte Frames** | 23458 | 39.10 Hz | Dem Forward+ Renderer übergebene Frames |

## 2. EFB-Kopierzuverlässigkeit

| Metrik | Wert |
|---|---:|
| Inventar-Zyklen (Auf / Zu) | 183 |
| EFB-Kopien erfasst & quittiert | 183 |
| Duplikat-Wiederholungen verarbeitet | 92 |
| **Verlorene EFB-Kopien** | **0** |

### Bewertung & Ergebnis
> [!IMPORTANT]
> **PASS**: 0 verlorene EFB-Kopien über 10 Minuten unter 33.3 % künstlichem Frame-Drop. Alle Sequenznummern wurden lückenlos vom Host retransmittiert und von Godot quittiert.
