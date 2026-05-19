# Transcription de réunion en direct

dictee peut transcrire et diariser une réunion en temps réel, segment par segment, avec une fenêtre dédiée et une synthèse LLM automatique à la fin.

## Démarrage rapide

1. Cliquer sur le bouton **Live meeting** du plasmoid (ou menu de la zone de notification)
2. Cliquer **▶ Démarrer** dans la fenêtre qui s'ouvre
3. Parler — le texte et les locuteurs apparaissent progressivement (~1 segment toutes les 30 s)
4. Cliquer **⏹ Arrêter** pour terminer — une synthèse LLM s'ouvre automatiquement

## Fonctionnement

dictee capture l'audio en continu avec `pw-record` dans un fichier WAV. Toutes les 30 secondes, un segment de 40 secondes avec 10 s de recouvrement est extrait et envoyé en parallèle à :

- **Parakeet** (via le `transcribe-daemon` existant, INT8 sur CPU) pour le texte
- **Sortformer streaming** (via `diarize-only --stream`) pour les locuteurs

Les résultats sont alignés par timestamps et ajoutés à `transcript-live.md`.

## Organisation des fichiers

Chaque réunion crée un dossier :

```
~/.local/share/dictee/meetings/YYYY-MM-DD-HHMM/
├── audio.wav              # capture audio complète (16 kHz mono)
├── transcript-live.md     # transcription avec étiquettes de locuteurs
├── transcript-segments.json  # données brutes pour recherche/export
├── summary.md             # synthèse LLM (générée à la fin)
├── meeting.meta.json      # durée, nb de locuteurs, langue, profil
└── chunks/                # segments de 40 s pour diagnostic
```

## Paramètres (dictee-setup → page Réunion)

- **Profil LLM** : `synthese`, `chapitrage`, `correction-asr`, personnalisé
- **Dossier de sauvegarde** : par défaut `~/.local/share/dictee/meetings/`
- **Durée d'un segment** : 20-60 s (par défaut 40 s)

## Limites

- Recommandé pour les réunions < 30 min avant la réinitialisation automatique de session
- Sortformer plafond = 4 locuteurs distincts (limitation du modèle NVIDIA)
- Multilingue via Parakeet TDT, 25 langues européennes
- Le PTT live (dictée F9) est désactivé pendant qu'une réunion est active

## Dépannage

- « transcribe-daemon socket absent » → démarrer le backend de dictée dans dictee-setup
- « diarize-only introuvable » → installer `dictee-cpu` ou `dictee-cuda` >= 1.4
- CPU élevé sur ancien matériel → augmenter la durée d'un segment à 60 s dans les paramètres
- Les locuteurs changent au milieu de la réunion → comportement attendu après la réinitialisation auto à 30 min ; voir `meeting.meta.json` pour les frontières de session

## Voir aussi

- [Diarisation (fichier)](diarization.fr.md)
- [Réglage anti-hallucination Whisper](whisper-tuning.fr.md)
- [Page matériel](hardware.fr.md)
