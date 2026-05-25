# Spec — Forçage Parakeet int8→CPU (master) + badge provider 3 couleurs

**Date :** 2026-05-25
**Cible :** v1.4 (master). La 1.3 a déjà le **forçage backend minimal** (`bfc0d18`,
`release/1.3`), sans badge ni grisages.
**Statut :** design validé (A+B). Grisages = phase 2 (hors scope, voir §8).

## 1. Problème

1. **int8 sur GPU est toujours lent** : l'ORT CUDA EP n'optimise pas les ops int8
   (fp32-GPU ~6× plus rapide qu'int8-GPU ; int8-CPU ~34 % plus rapide que fp32-CPU
   via AVX-VNNI). Le couple « int8 + GPU » n'a donc **jamais** d'intérêt. Or
   `transcribe_daemon` choisit le provider via `best_provider()` (GPU si dispo)
   **indépendamment du modèle** → un utilisateur avec le modèle int8 installé le
   fait tourner sur le GPU = pire cas. **Déjà corrigé en 1.3** ; master ne l'a pas.

2. **Le badge provider mentirait** : master écrit `/dev/shm/.dictee_provider`
   (badge GPU/CPU de l'UI) via `provider_status()`. Si on force le CPU pour int8
   sans rien d'autre, `provider_status()` renvoie `"cuda"` (GPU détecté) → le badge
   afficherait « GPU » alors qu'on tourne en CPU.

3. **Le badge met tout CPU en rouge** : aujourd'hui `cuda` = vert, **tout le reste**
   (cpu / cpu-forced / cpu-only) = rouge. Or seul `"cpu"` est une **panne** (libs
   CUDA cassées malgré GPU). Le CPU **voulu** (paquet CPU, CPU forcé, Whisper, Vosk,
   int8) ne devrait pas alarmer l'utilisateur en rouge.

## 2. Objectif

- **A** : sur master, Parakeet int8 s'exécute sur **CPU** (parité 1.3) **et** le
  badge reflète honnêtement le CPU.
- **B** : badge à **3 couleurs** distinguant GPU / CPU-voulu / CPU-panne.

## 3. Décision centrale — vocabulaire `.dictee_provider` → couleur

Règle unique, appliquée partout dans l'UI :

| Valeur écrite | Sens | Couleur |
|---|---|---|
| `cuda` | GPU utilisé | 🟢 vert |
| `cpu` | **PANNE** : GPU + paquet CUDA mais libs cassées → fallback subi | 🔴 rouge |
| `cpu-forced` / `cpu-only` / **`cpu-int8`** (nouveau) | CPU **voulu** | 🔵 bleu |

- Règle d'implémentation = `cuda → vert ; "cpu" → rouge ; tout le reste → bleu`.
  Le « tout le reste » rend `cpu-int8` bleu **sans** code dédié.
- **Vocabulaire déjà cohérent côté daemons** (vérifié 2026-05-25) : Whisper écrit
  `"cpu"` uniquement dans son garde-fou anormal et `"cpu-only"` en CPU normal
  (`transcribe-daemon-whisper:127-135`) ; Vosk écrit toujours `"cpu-only"`
  (`transcribe-daemon-vosk:158`). **Aucun daemon à modifier pour B.**

## 4. Composant A — backend (`src/bin/transcribe_daemon.rs`, master)

Au point de décision du provider (actuellement l. 165) :

1. Détecter si le modèle Parakeet **qui sera chargé** est int8. Helper local
   `parakeet_resolves_to_int8(model_dir)` reproduisant l'ordre de
   `ParakeetTDTModel::find_encoder` **master** (qui inclut `prefers_int8`) :
   ```
   int8_présent = encoder-model.int8.onnx existe
   is_int8 = int8_présent && ( prefers_int8()  ||  (fp32 absent : ni encoder-model.onnx ni encoder.onnx) )
   où prefers_int8() = DICTEE_PARAKEET_QUANT == "int8" (insensible à la casse)
   ```
   (En 1.3 le helper était plus simple — pas de `prefers_int8` côté Rust.)
2. `provider = if !use_canary && is_int8 { ExecutionProvider::Cpu } else { best_provider() }`.
3. Badge : si int8 forcé → écrire **`"cpu-int8"`** dans `/dev/shm/.dictee_provider`
   au lieu de `provider_status()` ; sinon comportement actuel (`provider_status()`).
4. Canary non concerné (GPU-only, pas de variante int8).

Tests unitaires (dans le binaire, comme en 1.3) sur la détection : int8 seul → vrai ;
fp32+int8 sans `DICTEE_PARAKEET_QUANT` → faux ; fp32+int8 avec `DICTEE_PARAKEET_QUANT=int8`
→ vrai ; aucun modèle → faux.

## 5. Composant B — badge 3 couleurs (UI)

Remplacer la règle binaire `cuda ? vert : rouge` par la règle à 3 états (§3) dans :

- `plasmoid/package/contents/ui/CompactRepresentation.qml` — le marqueur de coin
  (aujourd'hui lettre « G » verte/rouge).
- `plasmoid/package/contents/ui/FullRepresentation.qml` — affichage provider.
- `dictee-tray.py` — badge/menu de l'icône systray.
- `plasmoid/package/contents/ui/main.qml` — propagation de la valeur (vérifier
  s'il faut exposer la couleur ou juste la valeur brute aux deux représentations).

**Marqueur** (décision 2026-05-25) : une **lettre colorée, SANS cercle** (retirer le
cercle / `Rectangle` de fond actuel) :
- `cuda` → « **G** » **vert** (GPU utilisé)
- `cpu` → « **G** » **rouge** (GPU présent mais défaillant — libs CUDA cassées)
- `cpu-forced` / `cpu-only` / `cpu-int8` → « **C** » **bleu** (CPU voulu)

La lettre dit GPU (G) ou CPU (C) ; la couleur dit l'état (vert OK / rouge panne /
bleu CPU voulu). Bleu à aligner sur la palette KDE (accent / « info »).

## 6. Cohérence multi-backend

Aucun changement de daemon requis (§3). Au changement de backend, chaque daemon
réécrit `.dictee_provider` à son démarrage → le badge se met à jour. Canary =
toujours `cuda` (GPU-only).

## 7. Tests / vérification

- **A** : tests unitaires de détection (§4) + E2E (build release CUDA + GPU +
  modèle int8 → log « forcing CPU » + badge bleu, pas de tentative GPU).
- **B** : vérif visuelle des 3 couleurs en simulant les valeurs (écrire `cuda` /
  `cpu` / `cpu-int8` dans `/dev/shm/.dictee_provider` → badge vert / rouge / bleu),
  sur plasmoid **et** tray.

## 8. Hors scope — phase 2 (grisages, feature C séparée)

- « Parakeet précis » (fp32) **grisé** dans la liste quand le matériel ne peut pas
  le faire tourner (CPU-only ou GPU < 4 Go VRAM — critère `suggest_parakeet_quant`).
- Switch **GPU/CPU grisé** quand le mode int8 est actif (int8 → toujours CPU).
- Touche plasmoid (combobox/config) + tray (menu) + i18n. Spec dédiée le moment venu.

## 9. Fichiers touchés (A+B)

- `src/bin/transcribe_daemon.rs` (A : helper + forçage + valeur `cpu-int8`).
- `plasmoid/package/contents/ui/CompactRepresentation.qml`, `FullRepresentation.qml`,
  `main.qml` (B : règle couleur).
- `dictee-tray.py` (B : règle couleur).
