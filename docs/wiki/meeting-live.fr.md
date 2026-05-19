# Transcription de réunion en direct

dictee peut enregistrer une réunion en direct et transmettre l'audio à la fenêtre de transcription pour une diarisation complète, une analyse LLM et un export.

## Démarrage rapide

1. Cliquer sur le bouton **Live meeting** du plasmoid (ou menu de la zone de notification)
2. Cliquer **▶ Démarrer** dans la fenêtre qui s'ouvre
3. Parler — l'audio est capturé en continu
4. Cliquer **⏹ Arrêter et analyser** — la fenêtre de transcription s'ouvre automatiquement avec la diarisation activée

## Fonctionnement

dictee capture l'audio en continu avec `pw-record` dans un fichier WAV. Quand l'enregistrement est arrêté, il lance `dictee-transcribe --file audio.wav --diarize`, qui prend en charge :

- La transcription (Parakeet ou le backend configuré)
- La diarisation (Sortformer)
- L'analyse LLM (le profil configuré)
- L'export

## Organisation des fichiers

Chaque réunion crée un dossier :

```
~/.local/share/dictee/meetings/YYYY-MM-DD-HHMM/
├── audio.wav              # capture audio complète (16 kHz mono)
└── meeting.meta.json      # durée, taille audio, heure de fin
```

Les transcriptions, synthèses et exports sont produits par dictee-transcribe et enregistrés dans ce dossier.

## Paramètres (dictee-setup → page Réunion)

- **Dossier de sauvegarde** : par défaut `~/.local/share/dictee/meetings/`

## Dépannage

- « pw-record not found » → installer PipeWire (`pipewire-pulse` ou équivalent)
- « dictee-transcribe introuvable » → installer `dictee-cpu` ou `dictee-cuda` >= 1.4
- Le PTT live (dictée F9) est désactivé pendant qu'une réunion est active

## Voir aussi

- [Diarisation (fichier)](diarization.fr.md)
- [Page matériel](hardware.fr.md)
