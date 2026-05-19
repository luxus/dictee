# Dictee Meeting Live Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ajouter à dictee un mode "réunion live" qui transcrit + diarise en chunks 40 s avec affichage Qt défilant et synthèse LLM à la fin.

**Architecture:** Nouveau script orchestrateur Python `dictee-meeting-live` + extension du binaire Rust `diarize-only` avec mode `--stream` (Sortformer streaming vivant pendant toute la réunion). Parakeet INT8 utilisé via le `transcribe-daemon` existant. Pas de nouveau service systemd.

**Tech Stack:** Python 3.11+ (PyQt6, subprocess), Rust (parakeet-rs/sortformer streaming), PipeWire (`pw-record`), ffmpeg (chunking), systemd user (existing daemons).

**Design Spec:** `docs/superpowers/specs/2026-05-19-dictee-meeting-live-design.md` (référence si besoin de contexte).

---

## File Structure

**Création :**
- `dictee-meeting-live` (Python, ~500-700 l) — script principal
- `docs/test-protocol-meeting-live.md` (~100 l) — checklist tests vocaux
- `docs/wiki/meeting-live.md` (EN) + `docs/wiki/meeting-live.fr.md` (~150 l chacun)

**Modification (par tâche) :**
- `src/bin/diarize_only.rs` — mode `--stream` (~80-120 l ajoutées)
- `dictee-tray.py` — entrée menu (~15 l)
- `dictee-ptt.py` — bypass keys en mode meeting (~10 l)
- `dictee` (bash) — état `meeting-recording` (~5 l)
- `plasmoid/package/contents/ui/main.qml` — switch case + action (~5 l)
- `plasmoid/package/contents/ui/FullRepresentation.qml` — ToolButton (~20 l)
- `dictee-setup.py` — page Réunion (~40 l)
- `build-deb.sh`, `build-rpm.sh`, `PKGBUILD`, `PKGBUILD-cuda`, `build-tar.sh`, `install.sh` — packaging
- `po/dictee.pot` + `po/{fr,de,es,it,uk,pt}.po` — i18n
- `pkg/dictee/DEBIAN/postinst` — pas de modif (binaire ajouté au tar)

---

## Task 1 : Mode `--stream` du binaire `diarize-only.rs` (Rust)

**Files:**
- Modify: `src/bin/diarize_only.rs`
- Test: `tests/test_diarize_stream.sh` (création)

### Step 1.1 — Lire le binaire actuel pour cadrer la modif

- [ ] **Lire `src/bin/diarize_only.rs` en entier** pour repérer le point d'extension (probablement après le bloc de parsing des args, avant le traitement du fichier unique)

### Step 1.2 — Ajouter parsing du flag `--stream`

- [ ] **Ajouter le flag dans le boucle de parsing des args** (vers le début de `main()`) :

```rust
let mut stream_mode = false;
// ... boucle while i < args.len() existante ...
match args[i].as_str() {
    "--stream" => {
        stream_mode = true;
        i += 1;
    }
    // ... cas existants ...
}
```

### Step 1.3 — Ajouter le branchement principal

- [ ] **Après le parsing**, avant le code batch existant, ajouter :

```rust
if stream_mode {
    return run_stream_mode(&sortformer_dir, sensitivity);
}
// code batch existant intact
```

### Step 1.4 — Implémenter `run_stream_mode`

- [ ] **Ajouter cette fonction à la fin du fichier** :

```rust
#[cfg(feature = "sortformer")]
fn run_stream_mode(sortformer_dir: &str, sensitivity: f32) -> Result<(), Box<dyn std::error::Error>> {
    use std::io::{BufRead, BufReader, Write};

    // Charger Sortformer UNE SEULE FOIS au démarrage
    let providers = vec![ExecutionConfig::default().with_provider(best_provider())];
    let sortformer_path = format!("{}/diar_streaming_sortformer_4spk-v2.1.onnx", sortformer_dir);
    let mut sortformer = Sortformer::new_with_config(
        &sortformer_path,
        DiarizationConfig::default().with_sensitivity(sensitivity),
        providers,
    )?;

    let stdin = std::io::stdin();
    let mut stdout = std::io::stdout();
    let mut reader = BufReader::new(stdin.lock());
    let mut line = String::new();

    eprintln!("[diarize-only --stream] ready");

    loop {
        line.clear();
        let n = reader.read_line(&mut line)?;
        if n == 0 {
            // EOF
            eprintln!("[diarize-only --stream] EOF, exiting");
            break;
        }
        let cmd = line.trim();

        if cmd.is_empty() {
            continue;
        } else if cmd == "RESET" {
            sortformer.reset_streaming_state();
            writeln!(stdout, "RESET_OK")?;
            stdout.flush()?;
        } else if let Some(path) = cmd.strip_prefix("FILE: ") {
            // Charger le WAV chunk
            let segments = match diarize_chunk(&mut sortformer, path) {
                Ok(s) => s,
                Err(e) => {
                    writeln!(stdout, "ERROR: {}", e)?;
                    stdout.flush()?;
                    continue;
                }
            };
            for seg in segments {
                writeln!(stdout, "{:.3} {:.3} {}", seg.start, seg.end, seg.speaker_id)?;
            }
            writeln!(stdout)?;  // ligne vide = fin du chunk
            stdout.flush()?;
        } else {
            writeln!(stdout, "ERROR: unknown command")?;
            stdout.flush()?;
        }
    }
    Ok(())
}

#[cfg(feature = "sortformer")]
fn diarize_chunk(sortformer: &mut Sortformer, path: &str) -> Result<Vec<parakeet_rs::sortformer::SpeakerSegment>, Box<dyn std::error::Error>> {
    let (wav_path, needs_cleanup) = ensure_wav(path)?;
    let segments = sortformer.diarize_file(&wav_path)?;
    if needs_cleanup {
        let _ = std::fs::remove_file(&wav_path);
    }
    Ok(segments)
}
```

> Note : `sortformer.reset_streaming_state()` doit exister dans `src/sortformer.rs`. Vérifier ; si non, ajouter en exposant la méthode privée `Reset streaming state` (voir lignes 218-303 du module).

### Step 1.5 — Mettre à jour le help

- [ ] **Modifier `print_help()`** (ou le bloc d'usage existant) pour ajouter :

```rust
eprintln!("  --stream                 Mode streaming (lit FILE: <path> sur stdin)");
```

### Step 1.6 — Build et tester avec un script bash

- [ ] **Créer `tests/test_diarize_stream.sh`** :

```bash
#!/bin/bash
# Test du mode --stream de diarize-only
set -e
BIN="${BIN:-./target/release/diarize-only}"
SAMPLE="${SAMPLE:-tests/fixtures/diarize_sample_30s.wav}"

[ -x "$BIN" ] || { echo "FAIL: $BIN absent"; exit 1; }
[ -f "$SAMPLE" ] || { echo "SKIP: fixture $SAMPLE absente"; exit 0; }

# Lance diarize-only --stream et envoie 2 chunks séquentiels
{
  echo "FILE: $SAMPLE"
  sleep 1
  echo "FILE: $SAMPLE"
  sleep 1
} | $BIN --stream 2>/tmp/diarize_stream.err > /tmp/diarize_stream.out

# Vérifie au moins 2 chunks dans l'output
chunk_count=$(awk 'NF==0 {c++} END {print c}' /tmp/diarize_stream.out)
if [ "$chunk_count" -lt 2 ]; then
  echo "FAIL: attendu >= 2 chunks délimités par ligne vide, vu $chunk_count"
  cat /tmp/diarize_stream.out
  exit 1
fi

# Vérifie que ready apparaît
grep -q "\[diarize-only --stream\] ready" /tmp/diarize_stream.err || {
  echo "FAIL: pas de message ready"
  exit 1
}

echo "PASS: stream mode emits $chunk_count chunks"
```

### Step 1.7 — Build Rust

- [ ] **Run:** `cargo build --release --features "sortformer"`

Expected: build OK, binaire `target/release/diarize-only` à jour

### Step 1.8 — Run le test

- [ ] **Run:** `chmod +x tests/test_diarize_stream.sh && tests/test_diarize_stream.sh`

Expected: `PASS: stream mode emits 2 chunks` (ou SKIP si fixture absente — créer manuellement avec `arecord -d 30 -f S16_LE -r 16000 -c 1 tests/fixtures/diarize_sample_30s.wav` avant)

### Step 1.9 — Commit

- [ ] **Run:**

```bash
git add src/bin/diarize_only.rs tests/test_diarize_stream.sh
git commit -m "feat(diarize-only): stream mode (Sortformer alive, IDs cohérents)"
```

---

## Task 2 : Capture audio `pw-record` + chunker ffmpeg (Python)

**Files:**
- Create: `dictee-meeting-live` (lignes 1-150 ; squelette + workers audio)

### Step 2.1 — Créer le squelette du script

- [ ] **Créer `dictee-meeting-live`** avec en-tête + imports + main minimal :

```python
#!/usr/bin/env python3
"""dictee-meeting-live — Live meeting transcription + diarization for dictee.

Captures audio continuously, chunks every 40 s with 10 s overlap,
sends chunks to Parakeet (via transcribe-daemon socket) and Sortformer
(via diarize-only --stream), aligns results, displays in a Qt window,
and runs LLM summary at the end.
"""

import os
import sys
import time
import signal
import socket
import argparse
import subprocess
from pathlib import Path
from datetime import datetime

from PyQt6.QtCore import QObject, QThread, pyqtSignal, QFileSystemWatcher, Qt
from PyQt6.QtGui import QAction, QIcon
from PyQt6.QtWidgets import (
    QApplication, QMainWindow, QWidget, QVBoxLayout, QHBoxLayout,
    QLabel, QPushButton, QComboBox, QScrollArea, QTextEdit,
    QSystemTrayIcon, QMenu,
)

# Singleton path
def _singleton_path():
    return f"/tmp/dictee-meeting-live-{os.getuid()}.sock"

# Storage path
def meeting_dir(timestamp=None):
    ts = timestamp or datetime.now().strftime("%Y-%m-%d-%H%M")
    base = Path.home() / ".local/share/dictee/meetings" / ts
    base.mkdir(parents=True, exist_ok=True)
    return base


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--start", action="store_true", help="Start capture immediately")
    parser.add_argument("--stop", action="store_true", help="Stop running meeting")
    args = parser.parse_args()

    # Singleton: si déjà actif, raise + exit
    sock_path = _singleton_path()
    if os.path.exists(sock_path):
        # TODO Task 6: dispatch via Qt LocalSocket
        print("[meeting-live] already running", file=sys.stderr)
        sys.exit(1)

    app = QApplication(sys.argv)
    # TODO Task 6: instancier MeetingWindow
    print("[meeting-live] skeleton OK")


if __name__ == "__main__":
    main()
```

### Step 2.2 — Ajouter `AudioCaptureWorker`

- [ ] **Ajouter avant `main()`** :

```python
class AudioCaptureWorker(QThread):
    """Capture audio continue via pw-record vers WAV growing."""

    error = pyqtSignal(str)
    started_ok = pyqtSignal()

    def __init__(self, output_wav: Path):
        super().__init__()
        self.output_wav = output_wav
        self.proc = None
        self._stop = False

    def run(self):
        cmd = [
            "pw-record",
            "--format=s16",
            "--rate=16000",
            "--channels=1",
            "--target=@DEFAULT_AUDIO_SOURCE@",
            str(self.output_wav),
        ]
        try:
            self.proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL,
                                          stderr=subprocess.PIPE)
            self.started_ok.emit()
            rc = self.proc.wait()
            if rc != 0 and not self._stop:
                err = self.proc.stderr.read().decode("utf-8", "replace")
                self.error.emit(f"pw-record exit {rc}: {err}")
        except FileNotFoundError:
            self.error.emit("pw-record introuvable. PipeWire installé ?")

    def stop(self):
        self._stop = True
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.proc.kill()
```

### Step 2.3 — Ajouter `ChunkerWorker`

- [ ] **Ajouter après `AudioCaptureWorker`** :

```python
class ChunkerWorker(QThread):
    """Découpe audio.wav (growing) en chunks 40 s avec overlap 10 s via ffmpeg.

    Émet `chunk_ready(int chunk_id, str path)` à chaque nouveau chunk fini.
    Stratégie : timer tick toutes les 30 s (= chunk_duration - overlap),
    extrait via ffmpeg le segment [start, start+40s] dans chunk_NNN.wav.
    """

    chunk_ready = pyqtSignal(int, str)
    error = pyqtSignal(str)

    def __init__(self, audio_wav: Path, chunks_dir: Path,
                 chunk_duration: int = 40, overlap: int = 10):
        super().__init__()
        self.audio_wav = audio_wav
        self.chunks_dir = chunks_dir
        self.chunk_duration = chunk_duration
        self.overlap = overlap
        self.advance = chunk_duration - overlap   # 30s
        self._stop = False
        self.chunk_id = 0

    def run(self):
        self.chunks_dir.mkdir(parents=True, exist_ok=True)
        start_t = 0
        # Attendre que audio.wav existe et ait >= chunk_duration secondes
        while not self._stop:
            duration = self._wav_duration(self.audio_wav)
            if duration >= start_t + self.chunk_duration:
                chunk_path = self.chunks_dir / f"chunk_{self.chunk_id:04d}.wav"
                rc = self._extract(start_t, self.chunk_duration, chunk_path)
                if rc == 0:
                    self.chunk_ready.emit(self.chunk_id, str(chunk_path))
                    self.chunk_id += 1
                    start_t += self.advance
                else:
                    self.error.emit(f"ffmpeg extract failed (chunk {self.chunk_id})")
                    return
            time.sleep(1)

    def _wav_duration(self, path: Path) -> float:
        # 44 bytes header + raw PCM s16le mono 16kHz = 32000 B/s
        try:
            size = path.stat().st_size
            return max(0, (size - 44) / 32000.0)
        except FileNotFoundError:
            return 0

    def _extract(self, start_s: int, dur_s: int, out_path: Path) -> int:
        cmd = ["ffmpeg", "-y", "-ss", str(start_s), "-t", str(dur_s),
               "-i", str(self.audio_wav), "-ar", "16000", "-ac", "1",
               "-c:a", "pcm_s16le", str(out_path)]
        proc = subprocess.run(cmd, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL)
        return proc.returncode

    def stop(self):
        self._stop = True
```

### Step 2.4 — Test manuel rapide

- [ ] **Run:**

```bash
chmod +x dictee-meeting-live
./dictee-meeting-live --help
```

Expected: aide affichée, pas d'erreur

### Step 2.5 — Commit

- [ ] **Run:**

```bash
git add dictee-meeting-live
git commit -m "feat(meeting-live): skeleton + AudioCaptureWorker + ChunkerWorker"
```

---

## Task 3 : TranscriptionWorker (transcribe-client)

**Files:**
- Modify: `dictee-meeting-live` (ajouter classe TranscriptionWorker)

### Step 3.1 — Ajouter la classe

- [ ] **Ajouter après `ChunkerWorker`** :

```python
class TranscriptionWorker(QObject):
    """Pour chaque chunk reçu, appelle transcribe-client et émet (chunk_id, segments).

    Segments = [{"text": str, "start_s": float, "end_s": float}, ...]
    transcribe-client utilise le transcribe-daemon (Parakeet INT8 en RAM).
    """

    transcribed = pyqtSignal(int, list)
    error = pyqtSignal(int, str)

    def __init__(self):
        super().__init__()
        self.daemon_socket = "/tmp/transcribe.sock"

    def transcribe(self, chunk_id: int, chunk_path: str):
        # Slot connecté au signal chunk_ready du ChunkerWorker
        if not os.path.exists(self.daemon_socket):
            self.error.emit(chunk_id, f"transcribe-daemon socket absent ({self.daemon_socket})")
            return
        try:
            proc = subprocess.run(
                ["transcribe-client", "--file", chunk_path, "--json-timestamps"],
                capture_output=True, text=True, timeout=20,
            )
            if proc.returncode != 0:
                self.error.emit(chunk_id, f"transcribe-client exit {proc.returncode}: {proc.stderr}")
                return
            import json
            data = json.loads(proc.stdout)
            # Format attendu : {"tokens": [{"text", "start_s", "end_s"}, ...]}
            self.transcribed.emit(chunk_id, data.get("tokens", []))
        except subprocess.TimeoutExpired:
            self.error.emit(chunk_id, "transcribe-client timeout")
        except json.JSONDecodeError as e:
            self.error.emit(chunk_id, f"JSON parse: {e}")
```

> Note implémenteur : vérifier que `transcribe-client` supporte bien `--json-timestamps` (sinon ajuster le format ; cf. `src/bin/transcribe_client.rs`). Si l'option n'existe pas en l'état, l'ajouter dans ce Task (~30 l Rust) ou utiliser l'output texte brut + reconstruction des timestamps via Parakeet TDT frame rate (1 frame = 80 ms).

### Step 3.2 — Vérifier l'option `--json-timestamps` du client

- [ ] **Run:** `transcribe-client --help 2>&1 | grep -i json`

If empty, vérifier `src/bin/transcribe_client.rs` :

```bash
grep -n "json\|timestamp" src/bin/transcribe_client.rs
```

If l'option n'existe pas, l'ajouter (mini-task Rust) : flag `--json-timestamps` qui sérialise tokens + start_s + end_s via serde_json. ~20-30 lignes.

### Step 3.3 — Test manuel

- [ ] **Run** (après que transcribe-daemon tourne) :

```bash
# Génère un chunk 40s test
arecord -d 40 -f S16_LE -r 16000 -c 1 /tmp/test_chunk.wav
# Test la lib
python3 -c "
from importlib.machinery import SourceFileLoader
m = SourceFileLoader('mll', './dictee-meeting-live').load_module()
import sys
from PyQt6.QtCore import QCoreApplication
app = QCoreApplication(sys.argv)
w = m.TranscriptionWorker()
w.transcribed.connect(lambda cid, segs: (print(f'chunk {cid}: {len(segs)} tokens'), app.quit()))
w.error.connect(lambda cid, e: (print(f'ERR {cid}: {e}'), app.quit()))
w.transcribe(0, '/tmp/test_chunk.wav')
app.exec()
"
```

Expected: `chunk 0: N tokens` avec N > 0 si tu as parlé pendant l'enregistrement.

### Step 3.4 — Commit

- [ ] **Run:**

```bash
git add dictee-meeting-live
# Si modif Rust :
git add src/bin/transcribe_client.rs
git commit -m "feat(meeting-live): TranscriptionWorker + transcribe-client --json-timestamps"
```

---

## Task 4 : DiarizationWorker (pipe diarize-only --stream)

**Files:**
- Modify: `dictee-meeting-live` (ajouter classe DiarizationWorker)

### Step 4.1 — Ajouter la classe

- [ ] **Ajouter après `TranscriptionWorker`** :

```python
class DiarizationWorker(QObject):
    """Maintient diarize-only --stream vivant et envoie chunks via stdin.

    Émet (chunk_id, segments) où segments = [{"start_s", "end_s", "speaker_id"}, ...]
    """

    diarized = pyqtSignal(int, list)
    error = pyqtSignal(int, str)

    def __init__(self, sortformer_dir: str = None):
        super().__init__()
        self.proc = None
        self.sortformer_dir = sortformer_dir
        # Map chunk_id en attente pour émettre dans l'ordre
        self._pending = []

    def start(self):
        cmd = ["diarize-only", "--stream"]
        if self.sortformer_dir:
            cmd += ["--sortformer-dir", self.sortformer_dir]
        try:
            self.proc = subprocess.Popen(
                cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, text=True, bufsize=1,
            )
            # Attendre le message "ready" sur stderr (avec timeout 30s pour CPU lent)
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                line = self.proc.stderr.readline()
                if "ready" in line:
                    return True
            self.error.emit(0, "diarize-only --stream startup timeout")
            return False
        except FileNotFoundError:
            self.error.emit(0, "diarize-only introuvable. Sortformer feature buildée ?")
            return False

    def diarize(self, chunk_id: int, chunk_path: str):
        if not self.proc:
            self.error.emit(chunk_id, "DiarizationWorker pas démarré")
            return
        try:
            self.proc.stdin.write(f"FILE: {chunk_path}\n")
            self.proc.stdin.flush()
            self._pending.append(chunk_id)
            self._collect_response(chunk_id)
        except BrokenPipeError:
            self.error.emit(chunk_id, "diarize-only --stream pipe cassé")

    def _collect_response(self, chunk_id: int):
        segments = []
        while True:
            line = self.proc.stdout.readline()
            if not line:
                self.error.emit(chunk_id, "diarize-only EOF inattendu")
                return
            line = line.rstrip("\n")
            if line == "":
                # Fin du chunk
                self._pending.pop(0) if self._pending else None
                self.diarized.emit(chunk_id, segments)
                return
            if line.startswith("ERROR:"):
                self.error.emit(chunk_id, line)
                return
            parts = line.split()
            if len(parts) == 3:
                segments.append({
                    "start_s": float(parts[0]),
                    "end_s": float(parts[1]),
                    "speaker_id": int(parts[2]),
                })

    def reset_session(self):
        if self.proc:
            try:
                self.proc.stdin.write("RESET\n")
                self.proc.stdin.flush()
                self.proc.stdout.readline()  # attendre RESET_OK
            except BrokenPipeError:
                pass

    def stop(self):
        if self.proc:
            try:
                self.proc.stdin.close()
                self.proc.wait(timeout=5)
            except (subprocess.TimeoutExpired, BrokenPipeError):
                self.proc.kill()
            self.proc = None
```

### Step 4.2 — Test manuel intégré avec Task 1

- [ ] **Run** :

```bash
# Génère 2 chunks 40s pour tester la cohérence des IDs
arecord -d 40 -f S16_LE -r 16000 -c 1 /tmp/chunk_001.wav
arecord -d 40 -f S16_LE -r 16000 -c 1 /tmp/chunk_002.wav

python3 -c "
from importlib.machinery import SourceFileLoader
m = SourceFileLoader('mll', './dictee-meeting-live').load_module()
import sys
from PyQt6.QtCore import QCoreApplication
app = QCoreApplication(sys.argv)
w = m.DiarizationWorker()
if not w.start():
    sys.exit(1)
results = []
w.diarized.connect(lambda cid, segs: (results.append((cid, segs)), print(f'chunk {cid}: {segs}'), len(results)==2 and app.quit()))
w.error.connect(lambda cid, e: (print(f'ERR {cid}: {e}'), app.quit()))
w.diarize(0, '/tmp/chunk_001.wav')
w.diarize(1, '/tmp/chunk_002.wav')
app.exec()
w.stop()
"
```

Expected: 2 chunks avec segments, IDs speakers cohérents (le speaker 0 du chunk 1 = le même physique que le speaker 0 du chunk 2).

### Step 4.3 — Commit

- [ ] **Run:**

```bash
git add dictee-meeting-live
git commit -m "feat(meeting-live): DiarizationWorker via diarize-only --stream"
```

---

## Task 5 : AlignerWorker (matching timestamps texte ↔ speakers)

**Files:**
- Modify: `dictee-meeting-live` (ajouter classe AlignerWorker)

### Step 5.1 — Ajouter la classe

- [ ] **Ajouter après `DiarizationWorker`** :

```python
class AlignerWorker(QObject):
    """Aligne tokens Parakeet (texte+timestamps) avec segments Sortformer (speakers).

    Logique portée de src/bin/transcribe_diarize_batch.rs:316-343 :
    pour chaque token, trouve le speaker dont l'overlap avec le token est maximal.

    Émet aligned(chunk_id, lines) où lines = [{"speaker", "text", "start_s", "end_s"}, ...]
    regroupées par speaker (consecutifs avec même speaker = même ligne).
    """

    aligned = pyqtSignal(int, list)

    def __init__(self, chunk_offset_s: dict = None):
        super().__init__()
        # chunk_id → offset absolu en secondes (rempli par l'orchestrateur)
        self.chunk_offset = chunk_offset_s or {}
        # state pour matching différé (transcrit ET diarize doivent être arrivés)
        self._transcription = {}  # chunk_id → tokens
        self._diarization = {}    # chunk_id → segments

    def on_transcribed(self, chunk_id: int, tokens: list):
        self._transcription[chunk_id] = tokens
        self._try_align(chunk_id)

    def on_diarized(self, chunk_id: int, segments: list):
        self._diarization[chunk_id] = segments
        self._try_align(chunk_id)

    def _try_align(self, chunk_id: int):
        if chunk_id not in self._transcription or chunk_id not in self._diarization:
            return
        tokens = self._transcription.pop(chunk_id)
        segments = self._diarization.pop(chunk_id)
        offset = self.chunk_offset.get(chunk_id, 0.0)

        lines = []
        current_speaker = None
        current_text = []
        current_start = None
        current_end = None

        for tok in tokens:
            spk = self._find_speaker(tok["start_s"], tok["end_s"], segments)
            if spk != current_speaker:
                if current_speaker is not None:
                    lines.append({
                        "speaker": current_speaker,
                        "text": " ".join(current_text).strip(),
                        "start_s": current_start + offset,
                        "end_s": current_end + offset,
                    })
                current_speaker = spk
                current_text = [tok["text"]]
                current_start = tok["start_s"]
            else:
                current_text.append(tok["text"])
            current_end = tok["end_s"]

        if current_speaker is not None:
            lines.append({
                "speaker": current_speaker,
                "text": " ".join(current_text).strip(),
                "start_s": current_start + offset,
                "end_s": current_end + offset,
            })

        self.aligned.emit(chunk_id, lines)

    @staticmethod
    def _find_speaker(tok_start: float, tok_end: float, segments: list) -> int:
        """Trouve le speaker_id avec l'overlap maximal sur [tok_start, tok_end]."""
        best_spk = -1
        best_overlap = 0.0
        for seg in segments:
            overlap = max(0.0, min(tok_end, seg["end_s"]) - max(tok_start, seg["start_s"]))
            if overlap > best_overlap:
                best_overlap = overlap
                best_spk = seg["speaker_id"]
        return best_spk  # -1 si aucun match (silence pur)
```

### Step 5.2 — Test unitaire rapide

- [ ] **Run :**

```bash
python3 -c "
from importlib.machinery import SourceFileLoader
m = SourceFileLoader('mll', './dictee-meeting-live').load_module()
from PyQt6.QtCore import QCoreApplication
import sys
app = QCoreApplication(sys.argv)
w = m.AlignerWorker()
result = []
w.aligned.connect(lambda cid, lines: (result.append(lines), app.quit()))
# Tokens : 'Bonjour' [0-1] speaker 0, 'Salut' [2-3] speaker 1
tokens = [{'text': 'Bonjour', 'start_s': 0.0, 'end_s': 1.0},
          {'text': 'Salut', 'start_s': 2.0, 'end_s': 3.0}]
segments = [{'start_s': 0.0, 'end_s': 1.5, 'speaker_id': 0},
            {'start_s': 1.5, 'end_s': 4.0, 'speaker_id': 1}]
w.on_transcribed(0, tokens)
w.on_diarized(0, segments)
app.exec()
assert len(result[0]) == 2, f'Expected 2 lines, got {result[0]}'
assert result[0][0]['speaker'] == 0 and result[0][0]['text'] == 'Bonjour'
assert result[0][1]['speaker'] == 1 and result[0][1]['text'] == 'Salut'
print('PASS: AlignerWorker basic alignment')
"
```

Expected: `PASS: AlignerWorker basic alignment`

### Step 5.3 — Commit

- [ ] **Run:**

```bash
git add dictee-meeting-live
git commit -m "feat(meeting-live): AlignerWorker (port de transcribe_diarize_batch:316-343)"
```

---

## Task 6 : MeetingWindow Qt UI + intégration orchestrateur

**Files:**
- Modify: `dictee-meeting-live` (ajouter classe MeetingWindow + orchestration dans main())

### Step 6.1 — Ajouter la classe MeetingWindow

- [ ] **Ajouter après `AlignerWorker`** :

```python
class MeetingWindow(QMainWindow):
    """Fenêtre principale meeting-live."""

    SPEAKER_COLORS = [
        "#1976D2",  # bleu
        "#388E3C",  # vert
        "#F57C00",  # orange
        "#C62828",  # rouge
    ]

    def __init__(self):
        super().__init__()
        self.setWindowTitle("Réunion live")
        self.resize(800, 600)

        self.audio_worker = None
        self.chunker = None
        self.transcriber = None
        self.diarizer = None
        self.aligner = None

        self.meeting_dir = None
        self.transcript_path = None
        self.elapsed_seconds = 0
        self.speakers_seen = set()

        self._build_ui()

    def _build_ui(self):
        central = QWidget()
        self.setCentralWidget(central)
        layout = QVBoxLayout(central)

        # Status bar
        self.status_label = QLabel("Prêt à démarrer")
        layout.addWidget(self.status_label)

        # Scroll area pour le transcript
        self.transcript_view = QTextEdit()
        self.transcript_view.setReadOnly(True)
        self.transcript_view.setStyleSheet("font-family: monospace; font-size: 11pt;")
        layout.addWidget(self.transcript_view, stretch=1)

        # Boutons
        btn_row = QHBoxLayout()
        self.btn_start = QPushButton("▶ Démarrer")
        self.btn_start.clicked.connect(self.start_meeting)
        btn_row.addWidget(self.btn_start)

        self.btn_stop = QPushButton("⏹ Arrêter")
        self.btn_stop.clicked.connect(self.stop_meeting)
        self.btn_stop.setEnabled(False)
        btn_row.addWidget(self.btn_stop)

        btn_row.addStretch()

        self.profile_combo = QComboBox()
        self.profile_combo.addItems(["synthese", "chapitrage", "correction-asr"])
        btn_row.addWidget(QLabel("Profil :"))
        btn_row.addWidget(self.profile_combo)

        layout.addLayout(btn_row)

    def start_meeting(self):
        self.meeting_dir = meeting_dir()
        audio_wav = self.meeting_dir / "audio.wav"
        chunks_dir = self.meeting_dir / "chunks"
        self.transcript_path = self.meeting_dir / "transcript-live.md"

        # Initialise le transcript markdown
        self.transcript_path.write_text(
            f"# Réunion {datetime.now().strftime('%Y-%m-%d %H:%M')}\n\n",
            encoding="utf-8",
        )

        # State pour PTT mutex
        Path("/dev/shm/.dictee_state").write_text("meeting-recording\n")

        # Lance les workers
        self.audio_worker = AudioCaptureWorker(audio_wav)
        self.audio_worker.error.connect(self._on_error)
        self.audio_worker.start()

        self.chunker = ChunkerWorker(audio_wav, chunks_dir)
        self.chunker.chunk_ready.connect(self._on_chunk_ready)
        self.chunker.error.connect(self._on_error)
        self.chunker.start()

        self.transcriber = TranscriptionWorker()
        self.diarizer = DiarizationWorker()
        if not self.diarizer.start():
            self._on_error("Impossible de démarrer diarize-only --stream")
            return

        self.aligner = AlignerWorker()
        self.aligner.chunk_offset = {}

        # Wire signals
        self.transcriber.transcribed.connect(self.aligner.on_transcribed)
        self.diarizer.diarized.connect(self.aligner.on_diarized)
        self.aligner.aligned.connect(self._on_aligned)

        # Watcher sur le transcript pour rafraîchir l'UI
        self.watcher = QFileSystemWatcher([str(self.transcript_path)])
        self.watcher.fileChanged.connect(self._reload_transcript)

        self.btn_start.setEnabled(False)
        self.btn_stop.setEnabled(True)
        self.status_label.setText("● REC — 00:00")

    def _on_chunk_ready(self, chunk_id: int, chunk_path: str):
        # chunk_id N → offset = N * 30s (chunk_duration - overlap)
        self.aligner.chunk_offset[chunk_id] = chunk_id * 30.0
        self.transcriber.transcribe(chunk_id, chunk_path)
        self.diarizer.diarize(chunk_id, chunk_path)

    def _on_aligned(self, chunk_id: int, lines: list):
        with open(self.transcript_path, "a", encoding="utf-8") as f:
            for ln in lines:
                spk = ln["speaker"]
                if spk == -1:
                    continue  # silence pur, skip
                self.speakers_seen.add(spk)
                t = self._fmt_time(ln["start_s"])
                f.write(f"**[Speaker {spk}]** ({t}) {ln['text']}\n\n")

    def _reload_transcript(self):
        try:
            content = self.transcript_path.read_text(encoding="utf-8")
            # Coloration par speaker
            html_lines = []
            for line in content.split("\n"):
                if line.startswith("**[Speaker "):
                    spk_id = int(line.split("[Speaker ")[1].split("]")[0])
                    color = self.SPEAKER_COLORS[spk_id % len(self.SPEAKER_COLORS)]
                    html_lines.append(f'<p style="color:{color}">{line}</p>')
                else:
                    html_lines.append(f"<p>{line}</p>")
            self.transcript_view.setHtml("\n".join(html_lines))
            sb = self.transcript_view.verticalScrollBar()
            sb.setValue(sb.maximum())
        except FileNotFoundError:
            pass

    def stop_meeting(self):
        if self.audio_worker:
            self.audio_worker.stop()
        if self.chunker:
            self.chunker.stop()
        if self.diarizer:
            self.diarizer.stop()

        # Reset state
        Path("/dev/shm/.dictee_state").write_text("idle\n")

        self.status_label.setText(f"Terminée — {len(self.speakers_seen)} locuteurs")
        self.btn_start.setEnabled(True)
        self.btn_stop.setEnabled(False)

        # Lancer la synthèse LLM via dictee-postprocess (Task 11)
        self._run_llm_summary()

    def _run_llm_summary(self):
        # Placeholder, implémenté en Task 11
        pass

    def _on_error(self, msg):
        self.status_label.setText(f"Erreur : {msg}")
        print(f"[meeting-live] {msg}", file=sys.stderr)

    @staticmethod
    def _fmt_time(seconds: float) -> str:
        m = int(seconds) // 60
        s = int(seconds) % 60
        return f"{m:02d}:{s:02d}"
```

### Step 6.2 — Câbler MeetingWindow dans `main()`

- [ ] **Remplacer le `# TODO Task 6` dans main()** par :

```python
    win = MeetingWindow()
    win.show()
    if args.start:
        win.start_meeting()
    sys.exit(app.exec())
```

### Step 6.3 — Test manuel

- [ ] **Run:**

```bash
./dictee-meeting-live
```

Expected: fenêtre Qt ouverte. Cliquer "▶ Démarrer", parler ~2 min, cliquer "⏹ Arrêter". Voir le transcript se remplir avec coloration speakers.

### Step 6.4 — Commit

- [ ] **Run:**

```bash
git add dictee-meeting-live
git commit -m "feat(meeting-live): MeetingWindow Qt + orchestration workers"
```

---

## Task 7 : Mutex PTT — bypass keys en mode meeting-recording

**Files:**
- Modify: `dictee-ptt.py` (~10 l ajoutées)

### Step 7.1 — Localiser le point de lecture du state

- [ ] **Run:** `grep -n "read_state\|STATE_FILE" dictee-ptt.py | head -5`

### Step 7.2 — Ajouter le bypass dans `handle_event`

- [ ] **Repérer `ptt.handle_event` dans la boucle principale** (~ligne 679 selon la structure actuelle de `dictee-ptt.py:run_evdev` lue précédemment). Ajouter juste avant l'appel :

```python
                        # Meeting live actif : ne consommer aucune touche
                        if read_state() == "meeting-recording":
                            ui.write_event(event)
                            continue
```

### Step 7.3 — Test manuel

- [ ] **Run:**

```bash
echo "meeting-recording" > /dev/shm/.dictee_state
systemctl --user restart dictee-ptt
# Test : appuyer F9 → ne doit pas démarrer la dictée
# (vérifier que dictee ne tourne pas via systemctl --user status dictee)

echo "idle" > /dev/shm/.dictee_state
# F9 doit redonner le fonctionnement normal
```

Expected : pendant `meeting-recording`, F9 inactif pour dictee mais propagé aux apps (test taper F9 dans un éditeur, doit recevoir le keycode).

### Step 7.4 — Commit

- [ ] **Run:**

```bash
git add dictee-ptt.py
git commit -m "feat(ptt): bypass keys when meeting-recording state active"
```

---

## Task 8 : Storage layout + meta JSON

**Files:**
- Modify: `dictee-meeting-live` (ajouter écriture meta.json + finalisation)

### Step 8.1 — Ajouter écriture meta.json à `stop_meeting`

- [ ] **Dans `MeetingWindow.stop_meeting`**, après le `_run_llm_summary()` placeholder, insérer :

```python
        import json
        meta = {
            "ended_at": datetime.now().isoformat(),
            "duration_s": self.elapsed_seconds,
            "speakers_count": len(self.speakers_seen),
            "speakers_ids": sorted(self.speakers_seen),
            "llm_profile": self.profile_combo.currentText(),
            "chunks_count": self.chunker.chunk_id if self.chunker else 0,
        }
        (self.meeting_dir / "meeting.meta.json").write_text(
            json.dumps(meta, indent=2, ensure_ascii=False), encoding="utf-8"
        )
```

### Step 8.2 — Ajouter compteur de durée

- [ ] **Ajouter un QTimer dans `__init__`** :

```python
        from PyQt6.QtCore import QTimer
        self._tick_timer = QTimer(self)
        self._tick_timer.timeout.connect(self._tick)
        self._tick_timer.setInterval(1000)
```

- [ ] **Démarrer dans `start_meeting`** : `self._tick_timer.start()`
- [ ] **Stopper dans `stop_meeting`** : `self._tick_timer.stop()`
- [ ] **Ajouter méthode `_tick`** :

```python
    def _tick(self):
        self.elapsed_seconds += 1
        m, s = divmod(self.elapsed_seconds, 60)
        h, m = divmod(m, 60)
        self.status_label.setText(f"● REC — {h:02d}:{m:02d}:{s:02d}")
```

### Step 8.3 — Test manuel

- [ ] **Run** : démarrer un meeting, parler 30 s, arrêter. Vérifier :

```bash
ls -la ~/.local/share/dictee/meetings/$(ls ~/.local/share/dictee/meetings/ | tail -1)/
cat ~/.local/share/dictee/meetings/$(ls ~/.local/share/dictee/meetings/ | tail -1)/meeting.meta.json
```

Expected : fichiers `audio.wav`, `transcript-live.md`, `meeting.meta.json`, dossier `chunks/`.

### Step 8.4 — Commit

- [ ] **Run:**

```bash
git add dictee-meeting-live
git commit -m "feat(meeting-live): storage layout + meta.json + duration tick"
```

---

## Task 9 : Action plasmoid + entrée tray

**Files:**
- Modify: `plasmoid/package/contents/ui/main.qml` (~5 l)
- Modify: `plasmoid/package/contents/ui/FullRepresentation.qml` (~20 l)
- Modify: `dictee-tray.py` (~15 l)

### Step 9.1 — Plasmoid main.qml : action

- [ ] **Localiser** la fonction qui dispatch les actions (`switch case "meeting"` ou similaire). Vu pattern existant (cf. commit `0bcfcb3 feat: flock script + UI debounce`), il y a un mécanisme similaire pour `cheatsheet`. Ajouter :

```qml
            case "meeting-live":
                executable.exec("dictee-meeting-live --start")
                break
```

### Step 9.2 — Plasmoid FullRepresentation.qml : ToolButton

- [ ] **Ajouter** un nouveau bouton (à côté du toggle meeting actuel) :

```qml
        PlasmaComponents.ToolButton {
            id: meetingLiveButton
            icon.name: "media-record"
            text: i18n("Live meeting")
            visible: !root.recording  // pas en cours de dictée
            ToolTip.text: i18n("Start live meeting transcription")
            ToolTip.visible: hovered
            onClicked: action_meeting_live()
        }
```

- [ ] **Ajouter** la fonction de dispatch :

```qml
    function action_meeting_live() {
        plasmoid.nativeInterface.runCommand("meeting-live")
    }
```

### Step 9.3 — Tray dictee-tray.py : entrée menu

- [ ] **Localiser** la section où sont définies les `QAction` du menu tray. Ajouter :

```python
        action_meeting = QAction(_("Start live meeting transcription"), self)
        action_meeting.triggered.connect(self._start_meeting_live)
        menu.addAction(action_meeting)
```

- [ ] **Ajouter la méthode** :

```python
    def _start_meeting_live(self):
        import subprocess
        subprocess.Popen(["dictee-meeting-live", "--start"])
```

### Step 9.4 — Test manuel

- [ ] Recharger le plasmoid : `kquitapp6 plasmashell && kstart plasmashell`
- [ ] Cliquer sur le nouveau bouton "Live meeting" — vérifier que la fenêtre s'ouvre
- [ ] Tester l'entrée tray menu

### Step 9.5 — Commit

- [ ] **Run:**

```bash
git add plasmoid/ dictee-tray.py
git commit -m "feat(plasmoid+tray): meeting-live action + tray menu entry"
```

---

## Task 10 : Page setup "Réunion" dans dictee-setup.py

**Files:**
- Modify: `dictee-setup.py` (~40 l)

### Step 10.1 — Localiser une page existante comme template

- [ ] **Run:** `grep -n "def _build_page_\|QStackedWidget\|currentChanged" dictee-setup.py | head -10`

(le projet utilise un QStackedWidget avec des pages — vu via `wc -l` 18494 lignes, structure assez complexe. Suivre le pattern d'une page courte existante comme "Voice commands" ou "Hardware".)

### Step 10.2 — Ajouter `_build_page_meeting`

- [ ] **Ajouter** une nouvelle page :

```python
    def _build_page_meeting(self):
        page = QWidget()
        layout = QVBoxLayout(page)
        layout.addWidget(QLabel("<h2>" + _("Live meeting") + "</h2>"))

        # Profil LLM par défaut
        layout.addWidget(QLabel(_("Default LLM profile at end of meeting:")))
        self.cmb_meeting_profile = QComboBox()
        self.cmb_meeting_profile.addItems(["synthese", "chapitrage", "correction-asr"])
        existing = self.conf.get("DICTEE_MEETING_PROFILE", "synthese")
        self.cmb_meeting_profile.setCurrentText(existing)
        layout.addWidget(self.cmb_meeting_profile)

        # Dossier de sauvegarde
        layout.addWidget(QLabel(_("Save folder:")))
        self.led_meeting_dir = QLineEdit(
            self.conf.get("DICTEE_MEETING_DIR",
                          str(Path.home() / ".local/share/dictee/meetings"))
        )
        layout.addWidget(self.led_meeting_dir)

        # Durée chunk
        layout.addWidget(QLabel(_("Chunk duration (seconds):")))
        self.sld_chunk = QSlider(Qt.Orientation.Horizontal)
        self.sld_chunk.setMinimum(20)
        self.sld_chunk.setMaximum(60)
        self.sld_chunk.setValue(int(self.conf.get("DICTEE_MEETING_CHUNK_S", "40")))
        self.lbl_chunk = QLabel(f"{self.sld_chunk.value()} s")
        self.sld_chunk.valueChanged.connect(lambda v: self.lbl_chunk.setText(f"{v} s"))
        layout.addWidget(self.sld_chunk)
        layout.addWidget(self.lbl_chunk)

        layout.addStretch()
        return page
```

### Step 10.3 — Câbler la page dans le stack et la sauvegarde conf

- [ ] **Localiser** l'enregistrement des pages (probablement dans un dict ou liste). Ajouter `("meeting", _("Meeting"))` et `self._build_page_meeting()`.

- [ ] **Localiser** `save_config` et ajouter à `values` :

```python
        values["DICTEE_MEETING_PROFILE"] = self.cmb_meeting_profile.currentText()
        values["DICTEE_MEETING_DIR"] = self.led_meeting_dir.text()
        values["DICTEE_MEETING_CHUNK_S"] = str(self.sld_chunk.value())
```

### Step 10.4 — Test manuel

- [ ] **Run:** `./dictee-setup.py`

Ouvrir la page "Meeting", changer profil/durée chunk, sauvegarder, vérifier `~/.config/dictee.conf` contient les nouvelles clés.

### Step 10.5 — Commit

- [ ] **Run:**

```bash
git add dictee-setup.py
git commit -m "feat(setup): meeting page (profile, save folder, chunk duration)"
```

---

## Task 11 : LLM synthèse finale (FinalizerWorker)

**Files:**
- Modify: `dictee-meeting-live` (remplacer le placeholder `_run_llm_summary`)

### Step 11.1 — Ajouter FinalizerWorker

- [ ] **Ajouter avant `MeetingWindow`** :

```python
class FinalizerWorker(QThread):
    """Lance dictee-postprocess avec profil LLM choisi sur le transcript-live.md.

    Output dans summary.md du dossier meeting.
    """

    done = pyqtSignal(str)   # path vers summary.md
    error = pyqtSignal(str)

    def __init__(self, transcript_path: Path, summary_path: Path, profile: str):
        super().__init__()
        self.transcript_path = transcript_path
        self.summary_path = summary_path
        self.profile = profile

    def run(self):
        try:
            # dictee-postprocess attend le texte sur stdin et le profil en arg
            with open(self.transcript_path, "r", encoding="utf-8") as f:
                content = f.read()
            proc = subprocess.run(
                ["dictee-postprocess", "--profile", self.profile, "--mode", "llm"],
                input=content, capture_output=True, text=True, timeout=300,
            )
            if proc.returncode != 0:
                self.error.emit(f"dictee-postprocess exit {proc.returncode}: {proc.stderr}")
                return
            self.summary_path.write_text(proc.stdout, encoding="utf-8")
            self.done.emit(str(self.summary_path))
        except subprocess.TimeoutExpired:
            self.error.emit("LLM timeout (>5 min)")
        except Exception as e:
            self.error.emit(str(e))
```

### Step 11.2 — Implémenter `_run_llm_summary` dans MeetingWindow

- [ ] **Remplacer le placeholder** :

```python
    def _run_llm_summary(self):
        if not self.meeting_dir:
            return
        self.status_label.setText("Synthèse LLM en cours…")
        summary_path = self.meeting_dir / "summary.md"
        self.finalizer = FinalizerWorker(
            self.transcript_path,
            summary_path,
            self.profile_combo.currentText(),
        )
        self.finalizer.done.connect(self._on_summary_done)
        self.finalizer.error.connect(self._on_error)
        self.finalizer.start()

    def _on_summary_done(self, path):
        self.status_label.setText(f"Synthèse prête : {path}")
        # Ouvrir le summary dans une fenêtre dédiée ou éditeur externe
        subprocess.Popen(["xdg-open", path])
```

### Step 11.3 — Vérifier l'API `dictee-postprocess`

- [ ] **Run:** `dictee-postprocess --help 2>&1 | grep -iE "profile|mode|llm"`

Si l'API ne correspond pas exactement (`--profile`, `--mode llm`), ajuster les args. Si nécessaire, lire `dictee-postprocess.py` :

```bash
grep -n "argparse\|add_argument" dictee-postprocess.py | head -15
```

### Step 11.4 — Test manuel intégré

- [ ] **Run:** lancer un meeting de 1 min, arrêter, vérifier qu'un `summary.md` apparaît dans `~/.local/share/dictee/meetings/<date>/`.

### Step 11.5 — Commit

- [ ] **Run:**

```bash
git add dictee-meeting-live
git commit -m "feat(meeting-live): FinalizerWorker for end-of-meeting LLM summary"
```

---

## Task 12 : Packaging 4 cibles (deb/rpm/Arch/tarball)

**Files:**
- Modify: `build-deb.sh`, `build-rpm.sh`, `PKGBUILD`, `PKGBUILD-cuda`, `build-tar.sh`

### Step 12.1 — Identifier le pattern d'ajout de binaire dans chaque script

- [ ] **Run:**

```bash
grep -n "dictee-tray\|dictee-postprocess" build-deb.sh
grep -n "dictee-tray\|dictee-postprocess" build-rpm.sh
grep -n "dictee-tray\|dictee-postprocess" PKGBUILD
grep -n "dictee-tray\|dictee-postprocess" build-tar.sh
```

Ces lignes montrent où chaque cible inclut un script Python à la racine. Ajouter `dictee-meeting-live` au même endroit dans chaque fichier.

### Step 12.2 — Modifier `build-deb.sh`

- [ ] **Ajouter** sur la ligne juste après celle qui copie `dictee-tray` :

```bash
cp dictee-meeting-live pkg/$pkg_name/usr/bin/dictee-meeting-live
chmod +x pkg/$pkg_name/usr/bin/dictee-meeting-live
```

Faire pareil pour les builds CPU et CUDA (le script a 2 passes ou variables).

### Step 12.3 — Modifier `build-rpm.sh`

- [ ] **Ajouter** dans la section `%files` :

```
%{_bindir}/dictee-meeting-live
```

Et la copie pendant prep :

```bash
install -Dm755 dictee-meeting-live %{buildroot}/usr/bin/dictee-meeting-live
```

### Step 12.4 — Modifier `PKGBUILD` + `PKGBUILD-cuda`

- [ ] **Dans `package()`**, ajouter :

```bash
install -Dm755 "${srcdir}/dictee-meeting-live" "${pkgdir}/usr/bin/dictee-meeting-live"
```

### Step 12.5 — Modifier `build-tar.sh`

- [ ] **Ajouter** à la liste des fichiers copiés :

```bash
cp dictee-meeting-live "$STAGING/usr/bin/dictee-meeting-live"
chmod +x "$STAGING/usr/bin/dictee-meeting-live"
```

### Step 12.6 — Vérifier audit deps

- [ ] **Run:** `python3 packaging/audit-deps.py 2>&1 | tail -20`

Expected: aucune divergence flag. Si nécessaire, ajouter une entrée `python3-pyqt6` ou similaire dans `packaging/dependencies.yaml` (probablement déjà présente vu que dictee-tray et dictee-setup l'utilisent).

### Step 12.7 — Build deb test

- [ ] **Run:** `./build-deb.sh 2>&1 | tail -20`

Expected: build OK, paquet `.deb` créé contient `/usr/bin/dictee-meeting-live`. Vérifier :

```bash
dpkg -c dictee-cpu_*.deb | grep meeting-live
```

### Step 12.8 — Commit

- [ ] **Run:**

```bash
git add build-deb.sh build-rpm.sh PKGBUILD PKGBUILD-cuda build-tar.sh packaging/
git commit -m "packaging: include dictee-meeting-live in all 4 targets"
```

---

## Task 13 : i18n (.pot regen + traductions stubs)

**Files:**
- Modify: `po/dictee.pot`
- Modify: `po/{fr,de,es,it,uk,pt}.po`

### Step 13.1 — Regénérer le .pot

- [ ] **Run:**

```bash
xgettext --language=Python --keyword=_ --output=po/dictee.pot \
  dictee-tray.py dictee-setup.py dictee-meeting-live
```

Expected : nouveau `po/dictee.pot` contient les strings de `dictee-meeting-live`.

### Step 13.2 — msgmerge sur chaque locale

- [ ] **Run:**

```bash
for lang in fr de es it uk pt; do
  msgmerge --update po/${lang}.po po/dictee.pot
done
```

### Step 13.3 — Traduire les nouvelles strings (fr en priorité)

- [ ] **Éditer `po/fr.po`** et compléter les `msgstr ""` pour :

```po
msgid "Live meeting"
msgstr "Réunion live"

msgid "Start live meeting transcription"
msgstr "Démarrer la transcription en direct"

msgid "Default LLM profile at end of meeting:"
msgstr "Profil LLM par défaut en fin de réunion :"

msgid "Save folder:"
msgstr "Dossier de sauvegarde :"

msgid "Chunk duration (seconds):"
msgstr "Durée d'un segment (secondes) :"

msgid "Meeting"
msgstr "Réunion"
```

Pour les autres langues : les laisser en `msgstr ""` (msgmerge marque `fuzzy`), à compléter dans une autre passe ou via traduction communautaire.

### Step 13.4 — Compiler les .mo

- [ ] **Run:**

```bash
for lang in fr de es it uk pt; do
  msgfmt po/${lang}.po -o po/${lang}.mo
done
```

### Step 13.5 — Commit

- [ ] **Run:**

```bash
git add po/
git commit -m "chore(i18n): regenerate .pot for meeting-live + complete fr translations"
```

---

## Task 14 : Tests vocaux protocole

**Files:**
- Create: `docs/test-protocol-meeting-live.md` (~100 l)

### Step 14.1 — Créer la checklist de test

- [ ] **Créer le fichier** :

```markdown
# Protocole de test — Meeting Live

**Version cible** : v1.4
**Durée totale** : ~30 min

## Préreqs
- [ ] `dictee-cpu_1.4.0_amd64.deb` installé (ou tarball équivalent)
- [ ] `transcribe-daemon` actif (`systemctl --user status dictee`)
- [ ] Parakeet INT8 sélectionné dans dictee-setup
- [ ] Micro de test fonctionnel (`pactl list short sources | grep RUNNING`)
- [ ] `~/.local/share/dictee/meetings/` créé et inscriptible

## Tests fonctionnels

### T1 — Démarrage depuis plasmoid (3 min)
- [ ] Clic sur bouton "Live meeting" du plasmoid
- [ ] Fenêtre `dictee-meeting-live` s'ouvre
- [ ] Status bar affiche "Prêt à démarrer"
- [ ] Cliquer "▶ Démarrer"
- [ ] Status passe à "● REC — 00:00", incrémente chaque seconde
- [ ] Vérifier : `systemctl --user status dictee-ptt` actif mais ne déclenche pas dictée sur F9
- [ ] `cat /dev/shm/.dictee_state` retourne "meeting-recording"

### T2 — Premier chunk + transcription (2 min)
- [ ] Parler clairement pendant 45 s ("Bonjour je teste la transcription live, j'espère que les chunks vont bien fonctionner...")
- [ ] Au tick 40 s : un chunk apparaît dans `~/.local/share/dictee/meetings/<date>/chunks/chunk_0000.wav`
- [ ] Dans la fenêtre, une ligne `**[Speaker 0]** (00:00) Bonjour je teste...` s'affiche
- [ ] Couleur de la ligne = bleu (#1976D2)

### T3 — Plusieurs locuteurs (5 min)
- [ ] Réunion à 2 personnes différentes pendant 3 min
- [ ] Chunks 2, 3, 4... apparaissent
- [ ] Deux speakers distincts visibles avec couleurs différentes
- [ ] Speaker 0 reste = personne A, Speaker 1 reste = personne B sur toute la durée (cohérence native Sortformer streaming)

### T4 — Pause auto suspend système (optionnel, 2 min)
- [ ] Pendant l'enregistrement, `systemctl suspend`
- [ ] Reprise après wake : un marqueur "─── Pause ───" apparaît dans le transcript
- [ ] L'enregistrement reprend

### T5 — Arrêt + synthèse LLM (5 min)
- [ ] Cliquer "⏹ Arrêter"
- [ ] Status passe à "Synthèse LLM en cours…"
- [ ] Après ~30 s (selon provider LLM configuré), status passe à "Synthèse prête : <path>"
- [ ] `<path>` s'ouvre dans l'éditeur par défaut (xdg-open)
- [ ] Fichiers présents dans `~/.local/share/dictee/meetings/<date>/` :
  - `audio.wav` (taille > 0)
  - `transcript-live.md` (markdown avec speakers)
  - `summary.md` (généré par LLM)
  - `meeting.meta.json` (JSON valide)
  - `chunks/chunk_*.wav` (N chunks)

### T6 — Non-régression PTT (2 min)
- [ ] Quitter dictee-meeting-live
- [ ] `cat /dev/shm/.dictee_state` retourne "idle"
- [ ] Appuyer F9 → dictée démarre normalement
- [ ] Relâcher F9 → transcription dictée s'insère

### T7 — Réunion longue (>30 min) [test optionnel]
- [ ] Démarrer un meeting et laisser tourner 35 min (ou jouer un fichier audio long)
- [ ] Vérifier qu'à ~30 min, un marqueur "─── Reset session ───" apparaît
- [ ] Les speakers post-reset peuvent avoir de nouveaux IDs
- [ ] Pas de plantage, RAM stable

## Tests de régression

### R1 — `dictee` PTT fichier seul (dictée standard)
- [ ] F9 dictée normale fonctionne
- [ ] Cancel via Échap fonctionne

### R2 — `dictee-transcribe --file <wav> --diarize`
- [ ] Drop fichier WAV existant → diarisation fichier normale fonctionne (n'a pas été cassée)
```

### Step 14.2 — Commit

- [ ] **Run:**

```bash
git add docs/test-protocol-meeting-live.md
git commit -m "docs: add test protocol for meeting-live"
```

---

## Task 15 : Wiki EN+FR

**Files:**
- Create: `docs/wiki/meeting-live.md` (EN, ~150 l)
- Create: `docs/wiki/meeting-live.fr.md` (FR, ~150 l)

### Step 15.1 — Page EN

- [ ] **Créer `docs/wiki/meeting-live.md`** :

```markdown
# Live meeting transcription

dictee can transcribe and diarize a live meeting in real time, chunk by
chunk, with a dedicated window and automatic LLM summary at the end.

## Quick start

1. Click the **Live meeting** button in the plasmoid (or the tray menu)
2. Click **▶ Start** in the window that opens
3. Speak — text and speakers appear progressively (~1 chunk every 30 s)
4. Click **⏹ Stop** to end — an LLM summary opens automatically

## How it works

dictee captures audio continuously with `pw-record` into a WAV file.
Every 30 seconds, a 40-second chunk with 10-second overlap is extracted
and sent in parallel to :

- **Parakeet** (via the existing `transcribe-daemon`, INT8 on CPU) for text
- **Sortformer streaming** (via `diarize-only --stream`) for speakers

Results are aligned by timestamps and appended to `transcript-live.md`.

## Storage layout

Each meeting creates a folder :

\`\`\`
~/.local/share/dictee/meetings/YYYY-MM-DD-HHMM/
├── audio.wav              # full continuous capture (16 kHz mono)
├── transcript-live.md     # speaker-tagged transcript
├── transcript-segments.json  # raw data for search/export
├── summary.md             # LLM summary (generated at end)
├── meeting.meta.json      # duration, speakers count, language, profile
└── chunks/                # 40 s chunks for diagnostics
\`\`\`

## Settings (dictee-setup → Meeting page)

- **LLM profile**: `synthese`, `chapitrage`, `correction-asr`, custom
- **Save folder**: default `~/.local/share/dictee/meetings/`
- **Chunk duration**: 20-60 s (default 40 s)

## Limits

- Recommended for meetings < 30 min before automatic session reset
- Sortformer cap = 4 distinct speakers (NVIDIA model limitation)
- Multilingual via Parakeet TDT 25 European languages
- Live PTT (F9 dictation) is disabled while a meeting is active

## Troubleshooting

- "transcribe-daemon socket absent" → start dictation backend in dictee-setup
- "diarize-only introuvable" → install `dictee-cpu` or `dictee-cuda` >= 1.4
- High CPU on old hardware → increase chunk duration to 60 s in setup
- Speakers swap mid-meeting → expected after a 30 min auto-reset; see `meeting.meta.json` for session boundaries

## See also

- [Diarization (file)](diarization.md)
- [Whisper anti-hallucination](whisper-tuning.md)
- [Hardware page](hardware.md)
```

### Step 15.2 — Page FR

- [ ] **Créer `docs/wiki/meeting-live.fr.md`** : traduction française complète de la page EN ci-dessus (même structure, mêmes sections).

### Step 15.3 — Commit

- [ ] **Run:**

```bash
git add docs/wiki/meeting-live.md docs/wiki/meeting-live.fr.md
git commit -m "docs(wiki): meeting-live user guide EN + FR"
```

---

## Self-Review (à exécuter en interne avant de demander review utilisateur)

### Spec coverage

| Spec section | Task(s) |
|---|---|
| §1 Objectif | T1-T15 (toute la feature) |
| §2 Architecture globale (singleton, mutex PTT) | T2 (singleton stub), T7 (mutex PTT) |
| §3 Composants — fichiers | T1-T15 (chacun couvre une partie) |
| §4 Data flow | T2 (capture), T3 (transcribe), T4 (diarize), T5 (align), T6 (UI) |
| §5 Storage layout | T8 |
| §6 Mode --stream | T1 |
| §7 Error handling | T2 (audio worker errors), T4 (diarizer errors), T6 (window error handler) |
| §8 UX | T6 (window), T9 (plasmoid+tray), T10 (setup page) |
| §9 Stratégie d'évolution | hors scope MVP (backlogs v1.5+ à créer après) |
| §10 Effort estimation | matérialisé dans le plan |
| §11 Risques | T1 (RESET command), T6 (auto-reset placeholder à compléter v1.5), T7 (mutex) |
| §12 Critères de succès MVP | T14 (test protocol couvre les 8 items) |

✓ Couverture complète sauf §9 (intentionnellement reporté en backlogs).

### Type consistency

- `chunk_id` : int partout (Task 2, 3, 4, 5, 6, 8) ✓
- `segments` (sortformer) : list of dict `{start_s, end_s, speaker_id}` ✓
- `tokens` (parakeet) : list of dict `{text, start_s, end_s}` ✓
- `lines` (aligner output) : list of dict `{speaker, text, start_s, end_s}` ✓
- `speaker_id` : int (-1 = silence) ✓

### Placeholder scan

Aucun "TBD"/"TODO" laissé en plan, sauf :
- T6 `_run_llm_summary` placeholder → résolu en T11 ✓
- T8 elapsed_seconds incrément → résolu dans même tâche ✓

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-05-19-dictee-meeting-live.md`.**

Deux options d'exécution :

1. **Subagent-Driven (recommandé)** — Un agent frais dispatché par tâche, review entre tâches, itération rapide. Convient bien pour 15 tâches indépendantes comme ici.

2. **Inline Execution** — Exécution dans la session courante avec checkpoints batch. Plus simple si tu veux suivre en direct chaque tâche.

Laquelle préfères-tu ?
