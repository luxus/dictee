# Live meeting transcription

dictee can record a live meeting and hand it off to the transcription window for full diarization + LLM analysis + export.

## Quick start

1. Click the **Live meeting** button in the plasmoid (or the tray menu)
2. Click **▶ Start** in the window that opens
3. Speak — audio is captured continuously
4. Click **⏹ Stop and analyze** — the transcription window opens automatically with diarization enabled

## How it works

dictee captures audio continuously with `pw-record` into a WAV file. When you stop the recording, it launches `dictee-transcribe --file audio.wav --diarize`, which handles:

- Transcription (Parakeet or your configured backend)
- Speaker diarization (Sortformer)
- LLM analysis (your configured profile)
- Export

## Storage layout

Each meeting creates a folder:

```
~/.local/share/dictee/meetings/YYYY-MM-DD-HHMM/
├── audio.wav              # full continuous capture (16 kHz mono)
└── meeting.meta.json      # duration, audio size, end time
```

Transcripts, summaries and exports are produced by dictee-transcribe and saved there too.

## Settings (dictee-setup → Meeting page)

- **Save folder**: default `~/.local/share/dictee/meetings/`

## Troubleshooting

- "pw-record not found" → install PipeWire (`pipewire-pulse` or equivalent)
- "dictee-transcribe introuvable" → install `dictee-cpu` or `dictee-cuda` >= 1.4
- Live PTT (F9 dictation) is disabled while a meeting is active

## See also

- [Diarization (file)](diarization.md)
- [Hardware page](hardware.md)
