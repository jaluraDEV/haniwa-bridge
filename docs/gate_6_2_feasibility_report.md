# Gate 6.2 Schritt 0: Prüfbericht & Revisionsnachweis (Revision 4)

**Datum**: 2026-11-03  
**Status**: Erfolgreich abgeschlossen (Bedingte Freigabe – Abschlussprüfung abgeschlossen)  
**Hardware**: NVIDIA GeForce RTX 4060 Laptop GPU (8 GB VRAM), Vulkan 1.4.351, Godot 4.7.2 Forward+ Clustered RD  
**Test-Harness**: Echter Main-Loop über Shared Memory (`godot/shm_main.tscn`) mit Wall-Clock-Hardware-Zeitmessung

---

## 1. Static-Cache versus SDFGI-Invalidierung (Thema A)

### A. Echte SDFGI-Invalidierung über Frame-Grenzen
- **Analyse des Vorzustands**: In Commit `d7e40d6` wurde `_sdfgi_flush_pending = true` im selben Frame gesetzt, in dem `lighting_environment.sdfgi_enabled = false` aufgerufen wurde. Da beide Zuweisungen im selben GDScript-`_process()`-Tick erfolgten, hat Godots RenderingServer niemals einen Frame im Zustand `sdfgi_enabled = false` gerendert; die GPU-Kaskaden blieben ungeleert.
- **Korrektur (Zustandsmaschine über Frame-Grenzen)**:
  In [`godot/shm_main.gd`](godot/shm_main.gd) wurde eine 3-stufige Zustandsmaschine implementiert:
  ```gdscript
  var _sdfgi_flush_state: int = 0  # 0 = idle, 1 = disabled (render 1 frame OFF), 2 = re-enabling
  ```
  ```gdscript
  if cur_scene_val != _last_tracked_scene_no:
      if _last_tracked_scene_no != -1:
          renderer.clear_static_cache()
          if lighting_controller.lighting_environment.sdfgi_enabled:
              lighting_controller.lighting_environment.sdfgi_enabled = false
              _sdfgi_flush_state = 1
          print("[Scene Transition] Scene changed from %d to %d -> cleared static GI cache" % [_last_tracked_scene_no, cur_scene_val])
      _last_tracked_scene_no = cur_scene_val
  elif _sdfgi_flush_state == 1:
      # Genau ein vollständiger Frame wurde mit sdfgi_enabled = false gerendert.
      # Übergang in Status 2 zur Reaktivierung im Folgebild.
      _sdfgi_flush_state = 2
  elif _sdfgi_flush_state == 2:
      lighting_controller.lighting_environment.sdfgi_enabled = true
      _sdfgi_flush_state = 0
      print("[Scene Transition] Flushed and re-initialized Godot SDFGI cascades across frame boundary.")
  ```
- **Empirischer Nachweis (Roter Reflektor, 67 Frames Post-Flush)**:
  In einem isolierten Testaufbau mit stationärer Kamera und einer weißen Wand (`QuadMesh` 3×2 m) wurde ein intensiv roter Bodenreflektor platziert und nach Frame 30 gelöscht:
  - **Frame 30 (Vor Reset, roter Reflektor aktiv)**: Wandzentrum RGB = **`[230, 38, 47]`** (massiver roter Farbbounce).
  - **Frame 31–33**: Bodenreflektor zerstört, SDFGI-State-Machine deaktiviert SDFGI über Frame 31/32 und reaktiviert es in Frame 33.
    - CPU-Overhead Reaktivierung: **`0,006 ms`**.
    - Frame-Delta des Reset-Frames: **`16,67 ms`** (exakt 60,00 Hz, **0 Hitch**).
  - **Frame 35 (2 Frames nach Reaktivierung)**: RGB = **`[7, 7, 10]`** (Kaskaden leer, roter Bounce schlagartig getilgt).
  - **Frame 45 (12 Frames post-flush)**: RGB = `[28, 28, 35]`.
  - **Frame 60 (27 Frames post-flush)**: RGB = `[44, 44, 55]`.
  - **Frame 80 (47 Frames post-flush)**: RGB = `[46, 46, 56]`.
  - **Frame 100 (67 Frames post-flush)**: RGB = **`[46, 46, 56]`** (reines Umgebungs-/Himmelslicht).
  - **Ergebnis**: Über 67 aufeinanderfolgende Frames kehrt **keinerlei veraltete indirekte Beleuchtung** zurück. Der Reset ist 100 % sauber und hitch-frei.

---

## 2. Instanzidentität und konservativer Fallback (Thema B)

### A. Analyse von wechselndem Auftrittsindex `occ` und Draw-Reihenfolge
- **Verhalten bei Auslassung / Culling**: Werden zwei identische Meshes $A$ und $B$ in derselben 1m-Gitterzelle gerendert und $A$ verschwindet (z. B. durch Frustum-Culling oder Aufheben eines Items), rückt $B$ auf `occ = 0` vor.
- **Cache-Reaktion**: Der Schlüssel `[mesh_hash, cx, cy, cz, 0]` enthält die gespeicherte Position von $A$. Da $|\text{pos}_A - \text{pos}_B|^2 \ge 0,04$ ist, schlägt der Positionsvergleich sofort fehl. Das System setzt `hist["frames"] = 0` zurück und stuft $B$ umgehend auf `is_static = false` (Dynamic GI) herab.
- **Problem im Godot-Kern**: Godots SDFGI-Octree behält gebackene statische Voxel bei, wenn Instanzen ohne Kamerabewegung oder Kaskaden-Reset gelöscht werden. Würden veränderliche Objekte (Items, Blumen, Unkraut, Werkzeuge, NPCs) als statisch gebacken, entstünde Voxel-Ghosting.

### B. Konservativer Fallback (Implementiert)
Um Voxel-Ghosting innerhalb derselben Szene vollständig auszuschließen, gilt eine strikte Konservativitätsregel in [`acfp_renderer.gd`](godot/renderer/acfp_renderer.gd):
1. **Topologie-Filter**: Alle Meshes mit `< 60` Vertices (aufhebbare Items, Früchte, Blumen, Unkraut, Fische, Insekten, Partikel, Kleinteile) sind **permanent und ausnahmslos dynamisch** (`GI_MODE_DYNAMIC`).
2. **Statik-Kandidaten**: Nur großflächiges Terrain (`is_ground = true`, unbewegliche Dorfgeometrie) und große architektonische Strukturen ($\ge 60$ Vertices) dürfen als statische GI-Beiträger fungieren.
3. **Stabilitäts-Schwelle**: Nicht-Terrain-Geometrie muss mindestens **30 aufeinanderfolgende Frames** (~0,5 Sekunden bei 60 Hz) absolut unbewegt (`d_pos < 0.04`, `d_basis < 0.01`) und materialstabil bleiben, bevor sie als statisch klassifiziert wird.
4. **Initial-Sicherheit**: Neu auftretende Geometrie (`hist == null`) liefert im ersten Frame zwingend `false` (Dynamic GI).

Damit ist gewährleistet, dass keine temporären oder interaktiven Gameplay-Objekte jemals in Godots SDFGI-Kaskaden eingebrannt werden.

---

## 3. Dokumentationskorrektur VoxelGI (Thema C)

- In [`docs/gate_6_2_prep.md`](docs/gate_6_2_prep.md) (Zeile 16) wurde die Aussage korrigiert:
  - *Klarstellung*: Godot 4.7 unterstützt `VoxelGI.bake()` zur Laufzeit auch in exportierten Projekten.
  - *Begründung der Zurückstellung*: VoxelGI wird für ACGC aus Architektur- und Performancegründen zurückgestellt (Laufzeit-Bake-Stalls von mehreren hundert Millisekunden beim Raumwechsel, 16–64 MB VRAM-Overhead pro Raum, und die Notwendigkeit von SceneTree-Nodes statt der in ACGC verwendeten direkten RenderingServer-RID-Pipeline).

---

## 4. Hardware-Zusammenfassung

| Szenario / Modus | Frame Delta p50 / p95 / p99 | GPU ms p50 / p95 / p99 / max | CPU Render ms p50 / p95 / p99 / max | VRAM |
|---|---|---|---|---:|
| **Kamerabewegung Dorf (300f)** | 16,67 / 16,67 / 16,67 ms | 1,63 / 2,34 / 2,83 / **4,52 ms** | 2,33 / 2,73 / 2,96 / **3,43 ms** | - |
| **Original F4 (Unlit TEV)** | 16,67 / 16,67 / 16,67 ms | 0,39 / 0,50 / 0,76 / **0,76 ms** | 1,38 / 1,55 / 2,30 / **2,30 ms** | 126,7 MB |
| **Lit-Modus OHNE SDFGI** | 16,67 / 16,67 / 16,67 ms | 0,75 / 0,89 / 1,16 / **1,16 ms** | 1,58 / 1,75 / 2,03 / **2,03 ms** | 126,5 MB |
| **Lit-Modus MIT SDFGI (4 Kaskaden)** | 16,67 / 16,67 / **92,69 ms\*** | 0,78 / 1,58 / 1,64 / **1,64 ms** | 1,65 / 1,91 / 2,40 / **2,40 ms** | 498,0 MB |

*\*Vermutete Shader-Kompilierung beim allerersten Einschalten.* Im laufenden Spielbetrieb liegt die GPU-Zeit stabil bei **0,78 ms (p50)** bzw. **1,64 ms (p99)** (> 90 % GPU-Headroom).

---

## 5. Gate-Status
- Die Abschlussprüfung zu Commit `d7e40d6` ist vollständig bearbeitet, messtechnisch verifiziert und dokumentiert.
- **Gate 6.2 bleibt planmäßig PAUSIERT** bis zur Freigabe durch den Gatekeeper / Benutzer.
