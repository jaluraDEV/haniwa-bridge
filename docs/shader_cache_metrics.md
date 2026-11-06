# Shader-Cache Analyse & Messbericht

## 1. Ursachenanalyse der Warnungen (`f.is_null()`)

### Symptom
Beim Beenden oder Rendern dynamisch erzeugter Shader-Pipelines (insbesondere bei `cleanup()` oder Shader-Freigabe) trat folgende Fehlermeldung auf:
```text
ERROR: Condition "f.is_null()" is true.
   at: _save_to_cache (servers/rendering/renderer_rd/shader_rd.cpp:696)
```

### Wurzelursache
1. **Fehlende Zwischenverzeichnisse in Godot 4.7 Forward+ RD**:
   In `servers/rendering/renderer_rd/shader_rd.cpp::_save_to_cache` generiert Godot einen relativen Cache-Dateipfad der Form:
   `user://shader_cache/SceneForwardClusteredShaderRD/<group_sha256>/<variant_sha1>.<api>.cache`
   Godot ruft vor dem Schreibversuch `FileAccess::open(path, FileAccess::WRITE)` auf, **ohne** zuvor zu prüfen, ob das Zwischenverzeichnis für den Shader-Gruppenhash (`<group_sha256>`) existiert (`make_dir_recursive` fehlt an dieser Stelle im Engine-Code).
2. **Dynamische Shader-Kompilierung vs. Standard-Import**:
   Beim Import durch den Godot-Editor werden für statische Built-in-Shader die Verzeichnisse der Gruppenhashes automatisch vorangelegt. Sobald jedoch zur Laufzeit ein neuer benutzerdefinierter Shader kompiliert wird (wie der in Phase 5.5 eingeführte PBR-Wasserschader `acgc_water.gdshader`), existiert dieser Hash-Ordner noch nicht. Der Schreibaufruf scheitert mit `f.is_null()`.
3. **Persistente Cache-Aktivierung**:
   In `godot/project.godot` war `rendering/shader_compiler/shader_cache/enabled=true` noch nicht explizit eingetragen.

---

## 2. Technische Lösung

1. **IAT Auto-Directory Hook in `bridge/src/acgc_shm_client.c`**:
   - Da `Godot_v4.7.2-stable_win64.exe` C-Dateizugriffe über `msvcrt.dll` (`_wfopen` und `_wfopen_s`) ausführt, fängt die 64-Bit-GDExtension beim Laden die IAT-Einträge für `_wfopen` und `_wfopen_s` ab.
   - Falls ein Schreibzugriff auf einen Pfad mit `shader_cache` fehlschlägt, erzeugt `Hook_wfopen` / `Hook_wfopen_s` automatisch alle fehlenden Elternverzeichnisse (`ensure_parent_dirs_w`) und wiederholt den Öffnungsversuch erfolgreich.
   - Vollständig thread-sicher und transparent für die Engine.
2. **Projektkonfiguration (`godot/project.godot`)**:
   - `rendering/shader_compiler/shader_cache/enabled=true` aktiviert.

---

## 3. Messungen: Kaltstart vs. Warmstart (Erster Frame)

Gemessen auf NVIDIA GeForce RTX 4060 Laptop GPU (Vulkan 1.4.351 Forward+), Szene `captures/scene_village_day.acfp` (51 Drawcalls, 36 Pipeline-Varianten):

| Metrik | Kaltstart (Cache geleert) | Warmstart (Cache persistent) | Differenz |
| :--- | :---: | :---: | :---: |
| **Shader Warmup (36 Varianten)** | 1168,06 ms | 1009,52 ms | **-158,54 ms (-13,6 %)** |
| **First Frame `render_packet`** | 4,45 ms | 4,51 ms | Parität |
| **Startup bis erster Frame fertig** | **1179,32 ms** | **1049,77 ms** | **-129,55 ms** |
| **`Condition f.is_null()` Fehler** | **0** | **0** | **Behoben** |
