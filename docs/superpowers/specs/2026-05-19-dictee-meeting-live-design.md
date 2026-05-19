# Réunion live (meeting-live) — Design

**Date** : 2026-05-19
**Statut** : Brainstormé, en attente de plan d'implémentation
**Auteur** : Session interactive avec rcspam
**Tag cible** : v1.4

## 1. Objectif

Permettre à l'utilisateur de **transcrire et diariser une réunion en temps réel** (chunks 40 s avec overlap 10 s), avec affichage live texte + speakers dans une fenêtre dédiée, et synthèse LLM automatique à la fin.

Couvre les deux cas d'usage :
- **Réunion physique** (plusieurs personnes captées par le même micro)
- **Réunion visioconf** (zoom, meet, teams — micro local + son app)

### Contraintes utilisateur explicites

- Live avec lag sub-30 s (chunks 40 s avec overlap 10 s, latence par tick ~1-2 s)
- Multilingue (Parakeet TDT 25 langues)
- Speakers IDs cohérents nativement (Sortformer streaming maintient son état pendant la réunion)
- Usage primaire : comptes-rendus auto (LLM) + archive recherchable
- Pas de limite de durée (réunions 2 h+ OK)
- Tient sur T480 i7-8650U (CPU only) grâce à Parakeet INT8

## 2. Architecture globale

**Nouveau script orchestrateur Python** `dictee-meeting-live` (~500-700 lignes), processus autonome avec sa propre fenêtre Qt.

**Pattern singleton** : QLocalServer/QLocalSocket sur `dictee-meeting-live-${UID}`. Une seule réunion à la fois ; les invocations suivantes raise la fenêtre existante.

**CLI** :
- `dictee-meeting-live` : lance ou raise la fenêtre (sans démarrer la capture)
- `dictee-meeting-live --start` : démarre directement la capture
- `dictee-meeting-live --stop` : arrête la capture en cours

**Mutex avec PTT** : pendant un meeting actif, le PTT F9 est désactivé via flag dans `/dev/shm/.dictee_state` (valeur `meeting-recording`). `dictee-ptt.py` lit cet état et passe les touches sans déclencher la dictée.

## 3. Composants — fichiers à créer / modifier

| Fichier | Type | Lignes (estim.) | Rôle |
|---|---|---|---|
| `dictee-meeting-live` | **création** | ~500-700 | Script principal Python, fenêtre Qt, workers, orchestrateur |
| `src/bin/diarize_only.rs` | **modif** | +80-120 | Mode `--stream` (stdin chunks, Sortformer streaming vivant) |
| `dictee-tray.py` | modif | ~15 | Entrée menu : « Démarrer une réunion live » |
| `plasmoid/.../FullRepresentation.qml` | modif | ~20 | Bouton ToolButton + indicateur état `meeting-recording` |
| `plasmoid/.../main.qml` | modif | ~5 | Switch case `"meeting"` → exec `dictee-meeting-live --start` |
| `dictee-setup.py` | modif | ~40 | Onglet Réunion : profil LLM par défaut, dossier de sauvegarde, durée max chunk |
| `dictee-ptt.py` | modif | ~10 | Check `meeting-recording` dans state → bypass keys |
| `dictee` (script bash) | modif | ~5 | Comprend l'état `meeting-recording` pour state machine |
| `build-deb.sh` | modif | ~5 | Copie `dictee-meeting-live` dans pkg (cpu + cuda) |
| `build-rpm.sh` | modif | ~5 | Section `%files` (cpu + cuda) |
| `PKGBUILD` + `PKGBUILD-cuda` | modif | ~3 chacun | `install -Dm755 dictee-meeting-live ...` |
| `build-tar.sh` | modif | ~3 | Inclure dans tarball |
| `install.sh` mode_tarball | modif | ~3 | Idem |
| `po/dictee.pot` + `po/*.po` | regen | auto | Strings i18n × 6 langues (fr, de, es, it, uk, pt) |

### Aucun nouveau service systemd

Le binaire `diarize-only --stream` est lancé en sous-process par `dictee-meeting-live` au démarrage du meeting et killé à la fin (subprocess.Popen / proc.terminate). Pas de daemon résident.

### Structure interne du script `dictee-meeting-live`

```
dictee-meeting-live
├── main()                                  # parse args, singleton check, IPC dispatch
├── class MeetingWindow(QMainWindow)        # fenêtre Qt principale
│   ├── __init__()                          # layout (status bar + scroll view + boutons)
│   ├── _start_meeting()                    # crée dossier meeting, lance workers
│   ├── _stop_meeting()                     # arrête workers, lance synthèse LLM
│   ├── _on_transcript_changed()            # QFileSystemWatcher → update UI
│   ├── _on_chunk_ready(chunk_path)         # callback du chunker
│   └── closeEvent()                        # save geometry, stop meeting si actif
├── class AudioCaptureWorker(QThread)       # pw-record → audio.wav growing
├── class ChunkerWorker(QThread)            # ffmpeg → chunks 40s overlap 10s
├── class TranscriptionWorker(QThread)      # transcribe-client (Parakeet daemon)
├── class DiarizationWorker(QThread)        # diarize-only --stream (Sortformer streaming)
├── class AlignerWorker(QThread)            # matche timestamps texte ↔ speakers
└── class FinalizerWorker(QThread)          # LLM synthèse à la fin
```

## 4. Data flow détaillé

```
[pw-record continu]
   │
   ▼
~/.local/share/dictee/meetings/YYYY-MM-DD-HHMM/audio.wav  (growing)
   │
   ▼
[ChunkerWorker] ffmpeg → chunks 40 s overlap 10 s
   │
   ├─► chunk_001.wav  (sec [0, 40])
   ├─► chunk_002.wav  (sec [30, 70])
   ├─► chunk_003.wav  (sec [60, 100])
   │   ...
   ▼ (à chaque chunk fini, signal vers les 2 workers)
   │
   ├──► [TranscriptionWorker]
   │     transcribe-client < chunk_NNN.wav
   │     → JSON: [{"text", "start_s", "end_s"}, ...]
   │     (Parakeet INT8 daemon, ~0.7-1.3 s sur T480)
   │
   └──► [DiarizationWorker]
         Écrit "FILE: chunk_NNN.wav\n" sur stdin de diarize-only --stream
         Lit segments stdout: "start end speaker_id"
         → [{"start_s", "end_s", "speaker_id"}, ...]
         (Sortformer streaming vivant, IDs cohérents, ~0.5-1 s)
   │
   ▼ (les 2 workers ont fini)
   │
[AlignerWorker]
   Matche chaque token Parakeet avec le speaker actif au timestamp
   (port en Python de la logique transcribe_diarize_batch.rs:316-343)
   → [{"speaker", "text", "start_s", "end_s"}, ...]
   │
   ▼
~/.local/share/dictee/meetings/YYYY-MM-DD-HHMM/transcript-live.md  (append)
   │
   ▼ (QFileSystemWatcher de la fenêtre)
   │
[MeetingWindow]  défilement auto + coloration par speaker
```

## 5. Storage layout

```
~/.local/share/dictee/meetings/
└── 2026-05-19-1430/                     # YYYY-MM-DD-HHMM
    ├── audio.wav                         # capture continue (WAV 16 kHz mono)
    ├── transcript-live.md                # transcript live (markdown structuré)
    ├── transcript-segments.json          # données brutes pour relabel / recherche
    ├── summary.md                        # synthèse LLM (générée à la fin)
    └── meeting.meta.json                 # durée, nb speakers, langue, profil LLM
```

**Format `transcript-live.md`** :

```markdown
# Réunion 2026-05-19 14:30

**Durée** : 23:45
**Locuteurs détectés** : 3

## Transcription

**[Speaker 0]** (00:00) Bonjour à tous, on commence la réunion.
**[Speaker 1]** (00:08) Salut. J'ai préparé le rapport.
**[Speaker 0]** (00:14) Parfait, présente-le.
...
```

**Recherche future** (backlog v1.5) : un script `dictee-meeting-search "client X"` qui grep dans tous les `transcript-segments.json` du dossier meetings.

## 6. Mode `--stream` du binaire `diarize-only`

Comportement actuel : `diarize-only <audio.wav>` charge Sortformer, processe le fichier, exit.

Nouveau mode : `diarize-only --stream` reste vivant et lit chunks via stdin.

**Protocole stdin/stdout** :
```
> FILE: /path/to/chunk_001.wav\n
< 0.0 5.2 0
< 5.2 8.7 1
< 8.7 12.1 0
< \n                          # ligne vide = fin du chunk
> FILE: /path/to/chunk_002.wav\n
< 8.0 12.5 1                  # IDs maintenus grâce à Sortformer streaming
< 12.5 15.0 0
< \n
> (EOF / Ctrl+D)              # cleanup et exit
```

**Implémentation Rust** :
- Boucle `loop { read_line(stdin) ... }`
- Si `FILE: <path>` : load WAV, call `sortformer.process_chunk()` (la méthode streaming existante via `streaming_update()`), write segments
- Si EOF : break + cleanup
- État Sortformer (`smart cache` interne) maintenu entre chunks → IDs natifs cohérents
- Reset état via commande `RESET\n` (envoyé par `dictee-meeting-live` dans 3 cas : (1) checkpoint planifié toutes les 30 min sur réunions longues, (2) reprise après `pw-record` crash, (3) explicit nouvelle session après "Arrêter" puis re-démarrage)

Coût : ~80-120 lignes Rust ajoutées dans `diarize_only.rs`. Pas de breaking change (mode par défaut inchangé).

## 7. Error handling

| Scénario | Comportement |
|---|---|
| `pw-record` crash | Notif tray + bouton "Reprendre" → relance pw-record et continue le chunk en cours |
| `transcribe-daemon` indispo | Fallback : message "Démarre dictée d'abord" + lancement auto via `dictee-switch-backend` |
| `diarize-only --stream` crash | Restart auto avec nouvelle session (relabel sera fait à la finalisation) |
| Chunk corrompu (silence pur) | Skip, log dans `meeting.meta.json` |
| Disque plein | Stop meeting + notif critique, transcript-live.md préservé |
| OOM Sortformer (rare avec streaming) | Reset + ré-init + continuation |
| Session système killée (suspend) | Détection via timestamp gap > 60 s → marque "Pause" dans transcript |

## 8. UX

### Fenêtre Qt principale (`MeetingWindow`)

```
┌─────────────────────────────────────────────────────────────┐
│ Réunion live ─ 00:23:45                                ─ × │
├─────────────────────────────────────────────────────────────┤
│ ● REC  •  3 locuteurs  •  Parakeet INT8  •  fr             │  ← status bar
├─────────────────────────────────────────────────────────────┤
│                                                              │
│ [Speaker 0] (00:00) Bonjour à tous, on commence...           │  ← scroll view
│ [Speaker 1] (00:08) Salut. J'ai préparé le rapport.          │     défilement
│ [Speaker 0] (00:14) Parfait, présente-le.                    │     auto
│ ...                                                           │
│                                                              │
├─────────────────────────────────────────────────────────────┤
│ [⏸ Pause]              [Profil: synthèse ▾]    [⏹ Arrêter] │
└─────────────────────────────────────────────────────────────┘
```

- **Coloration** : 1 couleur Material-Design par speaker (jusqu'à 4)
- **Défilement** : auto-scroll vers le bas sauf si l'utilisateur a scrollé manuellement (sticky bottom pattern)
- **Pause** : suspend pw-record temporairement (utile pendant pause toilettes)
- **Profil LLM** : combobox alimentée par les profils existants (`synthese`, `chapitrage`, `correction-asr`, custom)
- **Arrêter** : confirme, stoppe workers, lance LLM synthèse, ouvre `summary.md` à la fin

### Plasmoid

Nouveau ToolButton dans `FullRepresentation.qml` à côté du toggle "Meeting" existant :
- Icône : `meeting-attending` (KDE standard) ou `media-record`
- Tooltip : "Démarrer une réunion live"
- État `meeting-recording` : icône rouge avec point clignotant
- Clic : exec `dictee-meeting-live --toggle`

### Tray (dictee-tray.py)

Entrée menu : « Démarrer une réunion live » (active si pas déjà en cours).

### Setup (dictee-setup.py)

Nouvelle page "Réunion" (ou section dans page existante) :
- Combobox profil LLM par défaut
- Champ dossier de sauvegarde (défaut : `~/.local/share/dictee/meetings/`)
- Checkbox "Auto-synthèse à la fin"
- Slider durée chunk (défaut 40 s, plage 20-60 s)

## 9. Stratégie d'évolution

### v1.4 MVP (ce design)
Tout ce qui est décrit ci-dessus.

### v1.5+ (backlogs séparés à créer)

1. **Recherche cross-meetings** : `dictee-meeting-search "client X"` script Python + UI page d'historique
2. **Mode 2-sources visioconf** : capture mic + app monitor en parallèle, pre-tag "moi" vs "eux", Sortformer pour fine-tune côté distant
3. **Nemotron 3.5 Streaming Multilingual** : quand NVIDIA libère le modèle (tracking actif), remplacer la chaîne `transcribe-client` + `diarize-only --stream` par `transcribe-stream-diarize` étendu — latence par tick proche de 0 ms
4. **Wake word "réunion"** : démarrage vocal de la capture (backlog `project-v14-wake-word-feasibility`)

## 10. Effort estimation

| Bloc | Effort |
|---|---|
| Modif `diarize-only.rs` mode `--stream` (Rust) | 3-5 h |
| Capture `pw-record` + chunker ffmpeg (Python) | 2 h |
| Worker tick TranscriptionWorker (`transcribe-client`) | 2-3 h |
| Worker tick DiarizationWorker (pipe diarize-only --stream) | 2-3 h |
| AlignerWorker timestamps (port logique Rust→Py) | 2-3 h |
| Fenêtre Qt MeetingWindow + QFileSystemWatcher | 4-5 h |
| Mutex PTT (`meeting-recording` dans state) | 1 h |
| Stockage meetings + format markdown | 2 h |
| Action plasmoid + entrée tray | 2 h |
| Page setup "Réunion" | 2 h |
| LLM synthèse finale | 1-2 h |
| Packaging 4 cibles | 2-3 h |
| i18n (.pot + 6 .po) | 1-2 h |
| Wiki EN + FR | 2-3 h |
| Tests vocaux (protocole) | 1-2 h |
| **Total v1.4 MVP** | **~30-40 h** |

## 11. Risques et mitigations

| Risque | Mitigation |
|---|---|
| Sortformer streaming → drift speakers sur réunions très longues (2h+) | Checkpoint + reset toutes les 30 min (pattern Meetily validé), avec ligne "─── Suite ───" dans transcript |
| Tick 40 s trop court sur très vieux CPU (< i5 8e gen) | Slider durée chunk dans setup (jusqu'à 60 s) ; détection auto et warning au démarrage si CPU sous seuil |
| ffmpeg chunker prend trop de RAM sur fichier audio.wav long | ffmpeg lit en mode tail/append, pas tout en mémoire ; alternativement, fragmentation directe via `ffmpeg -f segment` |
| `pw-record` peut être tué (suspend, OOM kill) | Détection via timestamp gap + restart auto + marquer "Pause" dans transcript |
| Régression sur PTT F9 si mutex mal géré | Test protocole vocal dédié + verrou flock symétrique aux patterns existants |

## 12. Critères de succès (MVP)

- [ ] Démarrer une réunion via plasmoid OU tray OU `dictee-meeting-live --start`
- [ ] Voir le transcript apparaître dans la fenêtre avec lag < 5 s par chunk (T480 CPU)
- [ ] Speakers correctement identifiés et stables sur 30 min de réunion à 2-3 locuteurs
- [ ] Arrêter génère un `summary.md` LLM utilisable
- [ ] PTT F9 reste fonctionnel hors meeting (non-régression)
- [ ] Marche sur les 4 cibles d'installation (deb/rpm/Arch/tarball)
- [ ] i18n 6 langues complète
- [ ] Aucune fuite VRAM/RAM après 3 cycles meeting start/stop
