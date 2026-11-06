# Phase 3b: Audio- und Frame-Pacing-Korrektur, 2026-11-01

## Nachgewiesene Ursachen

1. Der DAC erzeugt pro Syntheseschritt 560 Stereo-Frames bei 32 kHz,
   also 17,5 ms. Ein obligatorischer Syntheseschritt pro 60-Hz-Spiel-Tick
   produziert 33.600 statt 32.000 Stereo-Frames pro Sekunde. Zusätzliches
   Catch-up beschleunigt das Füllen. `AIInitDMA` kürzte überlaufende Blöcke
   stillschweigend. Der Underrun-Zähler konnte diesen Fehler nicht sehen.
2. Der alte Benchmark maß ausschließlich Arbeit innerhalb von
   `_physics_process`, ohne Engine-Rendering, Warten auf VSync oder tatsächliche
   Bildabstände. `tick_ms + render_ms` im Overlay addierte außerdem bereits
   parallel ausgeführte Arbeit. Der vermeintliche Dorf-Test hatte
   `scene_override=-1`, keine Eingaben und lief dadurch im Titelablauf.
3. Cache-Eviction durchsuchte für jedes alte Mesh/Material erneut sämtliche
   Instanzen. Diese Suche ist unnötig: Alle aktiven Slots sind vorher an die
   Ressourcen des aktuellen Frames gebunden, alle inaktiven Slots abgekoppelt.
4. Bildaufbereitung innerhalb des Physikcallbacks wurde beim Nachholen von
   Physikticks mehrfach ausgeführt. Nur das letzte dieser Bilder konnte
   tatsächlich ausgegeben werden.

## Änderungen

- `pc_audio_service_tick()` erzeugt bei aktivem Audiogerät nur bis zum
  Pufferziel; ohne Gerät bleibt ein deterministischer Syntheseschritt pro Tick.
  Synthese bleibt auf dem Spiel-Worker, ohne neuen konkurrierenden Audiozugriff
  auf Spielzustand. Pufferziel weiterhin 17.920 interleaved Samples / 280 ms.
- Verlorene Samples werden separat gezählt und durch die Bridge abgefragt.
  Kein `printf` mehr im zeitkritischen SDL-Callback. Ring-Differenzen werden
  vorzeichenlos berechnet; der Test überquert die signed-32-Bit-Grenze.
- Der Standalone-Produzent erreicht nun ebenfalls die Vorfüllschwelle; vorher
  lag sein Produktionsziel (4.480) unter der Startschwelle (17.920), was die
  Wiedergabe beim Start dauerhaft pausiert halten konnte.
- Spiel-Ticks bleiben bei 60 Hz. `_process` verarbeitet jeweils das neueste
  fertige Paket einmal; beim Nachholen werden nur überholte Darstellungen
  übersprungen, keine Spiel-Ticks.
- Redundante Eviction-Suchen entfallen; unveränderte Mesh-/Materialbindungen
  werden nicht erneut gesetzt. Statisch typisierte lokale Variablen vermeiden
  dynamische Operationen beim Dekodieren der Pakete und Vertices.
- Der Benchmark nutzt die echte Hauptszene. Gemessen werden getrennt
  CPU-Bildaufbereitung, Abstände zwischen Bildaufbereitungen und
  `RenderingServer.frame_post_draw`. Letzteres ist ein Engine-Signal,
  **keine Messung des physischen Monitor-Scanouts**.
- 60-FPS-Limit, VSync standardmäßig aus. Auf diesem Rechner ergab der sichtbare
  A/B-Test mit VSync 70 statt 0 Bildabstände über 20 ms. Ohne VSync kann Tearing
  auftreten. Die Einstellung bleibt in `godot/project.godot` änderbar.
  Hintergrund: [Godot-Dokumentation zu Jitter und VSync](https://docs.godotengine.org/en/latest/tutorials/rendering/jitter_stutter.html).

## Belege

Host: Godot 4.7.2 x86_32, Forward+, RTX 4060 Laptop GPU, gemeldete Anzeige 60 Hz.
Alle folgenden JSON-/Textdateien enthalten nur Messwerte, keine Spiel-Assets.

### Audio

`tools/test_audio_clock.sh` kompiliert einen assetfreien Test gegen das echte
SDL-Backend. Ein synthetisches, fortlaufendes PCM-Signal wird über 120 simulierte
Sekunden mit 60-Hz-Produktion und 32-kHz-Verbrauch auf Sample-Kontinuität geprüft.
Der korrigierte Ablauf erhält zusätzlich regelmäßig 100-ms-Spielthread-Pausen.

| Ablauf | Verworfene Samples | Underruns | Abweichende Ausgabesamples |
|---|---:|---:|---:|
| Alter obligatorischer Syntheseschritt + Catch-up | 338.240 | 0 | 6.694.912 |
| Verbrauchsgeregelte Produktion | 0 | 0 | 0 |

Beleg: [audio_clock.txt](measurements/2026-11-01/audio_clock.txt).
Die Anzahl abweichender Ausgabesamples zählt den verschobenen Signalverlauf nach
einem Verlust, nicht nur die direkt verlorenen Samples.

### Sichtbarer Titelablauf, 1.800 Bilder

Erste 300 Bilder als Boot-/Shader-Warm-up ausgeschlossen; Audioprobleme werden
ab Start gezählt. 187–290 Drawcalls, 1.500 gemessene Bildabstände.

| Messung | 60-FPS-Limit, VSync aus | 60-FPS-Limit, VSync an |
|---|---:|---:|
| Bildabstand p50 | 16,666 ms | 16,660 ms |
| Bildabstand p95 | 16,739 ms | 19,717 ms |
| Bildabstand p99 | 17,556 ms | 22,102 ms |
| Maximaler Bildabstand | 19,165 ms | 41,129 ms |
| Bildabstände über 20 ms | 0 | 70 |
| CPU-Bildaufbereitung p50 / p99 | 9,017 / 11,518 ms | 9,088 / 11,563 ms |
| Post-draw-Abstand p99 | 19,528 ms | 22,164 ms |
| Audioverluste / Underruns | 0 / 0 | 0 / 0 |

Belege: [Titel](measurements/2026-11-01/title_60fps.json),
[VSync-Vergleich](measurements/2026-11-01/title_vsync_comparison.json).
Der Puffer blieb zwischen 15.872 und 19.008 Samples (~248–297 ms).
Die Startphase enthält weiterhin Shader-/Ressourcenaufbau mit längeren Frames.

Ein ausgeblendetes Kontrollfenster war deutlich langsamer (3.600 Bilder in
80,33 s; p99 34,96 ms). Das belegt einen Einfluss des Fensterzustands in dieser
Messumgebung, isoliert aber nicht den konkreten Windows-/Treibermechanismus.
Beleg: [Hintergrund-Kontrolle](measurements/2026-11-01/hidden_window_control.json).

### Renderer-Parität und Ressourcen-Lebensdauer

`test_renderer_regression.tscn` vergleicht den vorherigen und aktuellen Renderer
in getrennten Viewports. 13 lokale Capture-Szenen werden dreimal durchlaufen.
Neue Ressourcen-IDs bei unveränderten Geometriedaten erzwingen Cache-Eviction;
unterschiedliche Drawcall-Mengen testen das Abkoppeln inaktiver Instanzen.

**39/39 Bilder byte-identisch, 1.811 Mesh-Evictions, keine Engine-Fehler.**
Beleg: [renderer_regression.txt](measurements/2026-11-01/renderer_regression.txt).
Dies belegt, dass diese Optimierung die bisherige Darstellung bewahrt, nicht
dass alle älteren Forward+-Abweichungen zum Originalspiel verschwunden sind.

## Reproduktion

Aus dem Projektverzeichnis mit vorhandener privater ISO und lokalen Captures:

```powershell
& "$env:USERPROFILE/msys64/usr/bin/bash.exe" tools/build_bridge.sh
& "$env:USERPROFILE/msys64/usr/bin/bash.exe" tools/test_audio_clock.sh
.\Godot_v4.7.2-stable_win32_console.exe --path godot -- --benchmark-frames 1800 --benchmark-output res://../scratch/title.json
.\Godot_v4.7.2-stable_win32_console.exe --path godot res://tests/test_village_5min.tscn -- --benchmark-output res://../scratch/village.json
```

Für Performance-Messungen das Spielfenster sichtbar lassen. Der Dorftest nutzt
explizit Szene 7; `--frames N` verkürzt ihn. Das Spiel wird nicht gespeichert.
Der Benchmark beendet sich bei Audioverlusten/Underruns mit Fehlercode 1.

Für den Pixelvergleich eine vorherige Renderer-Version als GDScript exportieren,
`class_name ACFPRenderer` darin zu `class_name ACFPBaselineRenderer` umbenennen und
`test_renderer_regression.tscn -- --baseline <absoluter Scriptpfad>` starten.

## Verbleibende Grenzen

- Kein vollständiger 30-Minuten-Audionachweis oder Durchlauf aller interaktiven
  Szenen/Spielstände. Keine Freigabe von Phase 4 oder Gate 6 daraus ableiten.
- Die Audiolatenz bleibt bewusst bei etwa 280 ms; eine spätere Verringerung
  benötigt eigene Tests mit kalten Shader-Caches und Szenenwechseln.
- Die API `shutdown_game()` ist bei erzwungenem Dorfstart ohne Spielstand nicht
  zuverlässig (Absturz im vorhandenen Scene-Destructor). Der normale App-Exit
  stoppt/joint den Worker und gibt Rendering-Ressourcen frei, ohne diesen neuen
  Destructor-Pfad aufzurufen; Prozessende räumt den Port wie bisher auf.


### Abschluss: sichtbarer 5-Minuten-Lauf mit Dorfstart

18.000 Bilder in **300,154 s** (~59,97 FPS einschließlich Start), 17.700
Messbilder nach Warm-up. Bildabstände p50/p95/p99 **16,666/16,735/17,104 ms**;
10 Abstände über 20 ms, Maximum 46,914 ms. Post-draw p99 18,054 ms.
CPU-Bildaufbereitung p50/p99 2,080/3,347 ms; 0–78 Drawcalls, 58,07 MB Godot
Static Memory. **0 Audioverluste, 0 Underruns**, Puffer 15.872–19.008 Samples.
Keine Engine-Fehler im stderr. Der erzwungene Dorfstart ohne Save läuft periodisch
über `toNextLand: l_keepSave not set` und `trademark_init` neu an; dieser Test
belegt daher fünf Minuten inklusive dieser Übergänge, kein durchgehend bewohntes
Dorf mit echtem Spielstand. Einzelne Übergänge verursachen weiter kurze Spitzen.
Beleg: [village_start_5min.json](measurements/2026-11-01/village_start_5min.json).
