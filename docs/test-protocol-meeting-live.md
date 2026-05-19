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
