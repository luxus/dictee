# Live meeting transcription

dictee can transcribe and diarize a live meeting in real time, chunk by chunk, with a dedicated window and automatic LLM summary at the end.

## Quick start

1. Click the **Live meeting** button in the plasmoid (or the tray menu)
2. Click **▶ Start** in the window that opens
3. Speak — text and speakers appear progressively (~1 chunk every 30 s)
4. Click **⏹ Stop** to end — an LLM summary opens automatically

## How it works

dictee captures audio continuously with `pw-record` into a WAV file. Every 30 seconds, a 40-second chunk with 10-second overlap is extracted and sent in parallel to:

- **Parakeet** (via the existing `transcribe-daemon`, INT8 on CPU) for text
- **Sortformer streaming** (via `diarize-only --stream`) for speakers

Results are aligned by timestamps and appended to `transcript-live.md`.

## Storage layout

Each meeting creates a folder:

```
~/.local/share/dictee/meetings/YYYY-MM-DD-HHMM/
├── audio.wav              # full continuous capture (16 kHz mono)
├── transcript-live.md     # speaker-tagged transcript
├── transcript-segments.json  # raw data for search/export
├── summary.md             # LLM summary (generated at end)
├── meeting.meta.json      # duration, speakers count, language, profile
└── chunks/                # 40 s chunks for diagnostics
```

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
