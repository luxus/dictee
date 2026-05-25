# Forçage int8→CPU (master) + badge provider 3 couleurs — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sur master (v1.4), exécuter Parakeet int8 sur CPU (jamais sur GPU, où il est lent) et refléter honnêtement le device dans un badge à 3 couleurs (GPU vert / CPU voulu bleu / CPU panne rouge).

**Architecture:** (A) `transcribe_daemon` détecte si le modèle Parakeet résolu est int8 et force `ExecutionProvider::Cpu`, en écrivant la valeur `cpu-int8` dans `/dev/shm/.dictee_provider`. (B) L'UI (plasmoid Compact/Full + tray) applique une règle couleur à 3 états : `cuda`→vert, `cpu`→rouge (panne), tout autre `cpu-*`→bleu. Aucun daemon Whisper/Vosk à modifier (vocabulaire déjà cohérent).

**Tech Stack:** Rust (ort/parakeet-rs), QML (Plasma 6 / Kirigami), Python (PyQt6 tray).

**Couleurs de référence** (hex, alignées sur FullRepresentation actuel) : vert `#27ae60`, rouge `#c0392b`, bleu `#3498db`.

**Spec :** `docs/superpowers/specs/2026-05-25-int8-cpu-forcing-provider-badge-design.md`

---

### Task 1: Backend — forçage int8→CPU + valeur `cpu-int8` (master)

**Files:**
- Modify: `src/bin/transcribe_daemon.rs` (import l.2, helper avant `fn main` l.69, config l.165, badge l.171)

- [ ] **Step 1: Écrire le test de détection (échoue)**

Ajouter avant `fn main()` (la fonction `parakeet_resolves_to_int8` n'existe pas encore) :

```rust
#[cfg(test)]
mod tests {
    use super::parakeet_resolves_to_int8;
    use std::fs;
    use std::path::PathBuf;

    fn tmp(tag: &str) -> PathBuf {
        let d = std::env::temp_dir()
            .join(format!("dictee_int8m_test_{}_{}", std::process::id(), tag));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn int8_only_is_int8() {
        let d = tmp("only_int8");
        std::env::remove_var("DICTEE_PARAKEET_QUANT");
        fs::write(d.join("encoder-model.int8.onnx"), b"").unwrap();
        assert!(parakeet_resolves_to_int8(&d));
        let _ = fs::remove_dir_all(&d);
    }

    #[test]
    fn fp32_present_without_pref_is_not_int8() {
        let d = tmp("fp32_int8_nopref");
        std::env::remove_var("DICTEE_PARAKEET_QUANT");
        fs::write(d.join("encoder-model.onnx"), b"").unwrap();
        fs::write(d.join("encoder-model.int8.onnx"), b"").unwrap();
        assert!(!parakeet_resolves_to_int8(&d));
        let _ = fs::remove_dir_all(&d);
    }

    #[test]
    fn prefers_int8_with_both_is_int8() {
        let d = tmp("fp32_int8_pref");
        std::env::set_var("DICTEE_PARAKEET_QUANT", "int8");
        fs::write(d.join("encoder-model.onnx"), b"").unwrap();
        fs::write(d.join("encoder-model.int8.onnx"), b"").unwrap();
        assert!(parakeet_resolves_to_int8(&d));
        std::env::remove_var("DICTEE_PARAKEET_QUANT");
        let _ = fs::remove_dir_all(&d);
    }

    #[test]
    fn no_model_is_not_int8() {
        let d = tmp("empty");
        assert!(!parakeet_resolves_to_int8(&d));
        let _ = fs::remove_dir_all(&d);
    }
}
```

- [ ] **Step 2: Lancer le test → échec compilation (fonction absente)**

Run: `cargo test --bin transcribe-daemon int8 2>&1 | tail -5`
Expected: erreur `cannot find function parakeet_resolves_to_int8`.

- [ ] **Step 3: Écrire le helper** (juste avant `fn main()`)

```rust
/// True si le modèle Parakeet qui SERA chargé depuis `model_dir` est int8.
/// Reproduit l'ordre de `ParakeetTDTModel::find_encoder` (master) : si
/// `DICTEE_PARAKEET_QUANT=int8`, l'int8 est prioritaire (chargé dès qu'il
/// existe) ; sinon le FP32 gagne et l'int8 n'est retenu que s'il est seul.
/// À garder synchrone avec find_encoder.
fn parakeet_resolves_to_int8(model_dir: &Path) -> bool {
    if !model_dir.join("encoder-model.int8.onnx").exists() {
        return false;
    }
    let prefers_int8 = std::env::var("DICTEE_PARAKEET_QUANT")
        .map(|v| v.eq_ignore_ascii_case("int8"))
        .unwrap_or(false);
    prefers_int8
        || (!model_dir.join("encoder-model.onnx").exists()
            && !model_dir.join("encoder.onnx").exists())
}
```

- [ ] **Step 4: Lancer le test → succès**

Run: `cargo test --bin transcribe-daemon int8 2>&1 | tail -8`
Expected: `test result: ok. 4 passed`.

- [ ] **Step 5: Ajouter `ExecutionProvider` à l'import** (l.1-4)

Remplacer :
```rust
use parakeet_rs::{
    best_provider, provider_status, Canary, ExecutionConfig, ParakeetTDT, TimestampMode,
    Transcriber, TranscriptionResult,
};
```
par :
```rust
use parakeet_rs::{
    best_provider, provider_status, Canary, ExecutionConfig, ExecutionProvider, ParakeetTDT,
    TimestampMode, Transcriber, TranscriptionResult,
};
```

- [ ] **Step 6: Forcer le CPU pour int8 + écrire `cpu-int8`** (l.164-171)

Remplacer :
```rust
    // Detects a usable NVIDIA GPU at runtime; falls back to CPU otherwise.
    let config = ExecutionConfig::new().with_execution_provider(best_provider());

    // Write detailed provider status to /dev/shm/.dictee_provider for UI
    // consumers (plasmoid badge, tray menu, dictee-setup). Best-effort —
    // if /dev/shm is not writable, just skip. See execution::provider_status()
    // for the value enum (cuda / cpu / cpu-forced / cpu-only).
    let _ = std::fs::write("/dev/shm/.dictee_provider", provider_status());
```
par :
```rust
    // Parakeet int8 is forced to CPU: the ORT CUDA EP doesn't optimize int8
    // ops (slower than int8 on CPU/AVX-VNNI), so int8 on the GPU is never
    // worthwhile. Canary has no int8 variant.
    let force_cpu_int8 = !use_canary && parakeet_resolves_to_int8(Path::new(&model_dir));
    let provider = if force_cpu_int8 {
        eprintln!("[dictee] Parakeet int8 model — forcing CPU (int8 is slow on the CUDA EP)");
        ExecutionProvider::Cpu
    } else {
        best_provider()
    };
    let config = ExecutionConfig::new().with_execution_provider(provider);

    // Write detailed provider status to /dev/shm/.dictee_provider for UI
    // consumers (plasmoid badge, tray menu, dictee-setup). "cpu-int8" is a
    // CPU-voulu value (blue badge); provider_status() would say "cuda" here.
    let _ = std::fs::write(
        "/dev/shm/.dictee_provider",
        if force_cpu_int8 { "cpu-int8" } else { provider_status() },
    );
```

- [ ] **Step 7: Vérifier la compilation des tests (sans casser les symlinks release)**

Run: `cargo test --bin transcribe-daemon int8 2>&1 | tail -8`
Expected: `test result: ok. 4 passed`. (debug → ne touche pas `target/release`.)

- [ ] **Step 8: Commit**

```bash
git add src/bin/transcribe_daemon.rs
git commit -m "feat(daemon): forcer le CPU pour Parakeet int8 sur master + badge cpu-int8

Parité avec release/1.3 (bfc0d18). Détection adaptée master (prefers_int8).
Écrit cpu-int8 dans /dev/shm/.dictee_provider pour que le badge UI reste
honnête (sinon provider_status() dirait cuda)."
```

---

### Task 2: Badge plasmoid compact — lettre G/C colorée sans cercle

**Files:**
- Modify: `plasmoid/package/contents/ui/CompactRepresentation.qml:206-234`

- [ ] **Step 1: Remplacer le Rectangle(cercle)+Text "G" par une lettre colorée sans cercle**

Remplacer le bloc l.206-234 :
```qml
    // Provider status marker: green "G" si cuda, rouge sinon (cpu / cpu-forced
    // / cpu-only). Toujours visible quand provider est connu — l'utilisateur
    // voit en permanence sur quel device tourne le daemon. Caché si l'instance
    // est passive (⊘ a la priorité) ou si provider vide (daemon pas démarré).
    Rectangle {
        visible: compact.isActive && compact.provider !== ""
        z: 99
        width: Math.max(8, Math.min(parent.width, parent.height) * 0.35)
        height: width
        radius: width / 2
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        color: compact.provider === "cuda"
            ? Kirigami.Theme.positiveBackgroundColor
            : Kirigami.Theme.negativeBackgroundColor
        border.color: compact.provider === "cuda"
            ? Kirigami.Theme.positiveTextColor
            : Kirigami.Theme.negativeTextColor
        border.width: 1
        Text {
            anchors.centerIn: parent
            text: "G"
            font.pixelSize: parent.width * 0.65
            font.bold: true
            color: compact.provider === "cuda"
                ? Kirigami.Theme.positiveTextColor
                : Kirigami.Theme.negativeTextColor
        }
    }
```
par :
```qml
    // Provider status marker: lettre colorée SANS cercle.
    //   G vert  = GPU (cuda) ; G rouge = GPU panne (cpu = libs CUDA cassées) ;
    //   C bleu  = CPU voulu (cpu-forced / cpu-only / cpu-int8).
    // La lettre dit GPU(G)/CPU(C), la couleur dit l'état.
    Text {
        visible: compact.isActive && compact.provider !== ""
        z: 99
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        text: (compact.provider === "cuda" || compact.provider === "cpu") ? "G" : "C"
        font.pixelSize: Math.max(8, Math.min(parent.width, parent.height) * 0.45)
        font.bold: true
        color: compact.provider === "cuda" ? "#27ae60"
             : compact.provider === "cpu"  ? "#c0392b"
             : "#3498db"
    }
```

- [ ] **Step 2: Redéployer le plasmoid + vérif visuelle**

```bash
kpackagetool6 -u "$(pwd)/plasmoid/package"
setsid plasmashell --replace >/dev/null 2>&1 &
# simuler les 3 états (laisser le badge se rafraîchir ~1s entre chaque) :
echo -n cuda     > /dev/shm/.dictee_provider   # → G vert
echo -n cpu      > /dev/shm/.dictee_provider   # → G rouge
echo -n cpu-int8 > /dev/shm/.dictee_provider   # → C bleu
```
Expected: le marqueur de coin affiche G vert / G rouge / C bleu, sans cercle de fond.

- [ ] **Step 3: Commit**

```bash
git add plasmoid/package/contents/ui/CompactRepresentation.qml
git commit -m "feat(plasmoid): badge provider compact — lettre G/C 3 couleurs sans cercle"
```

---

### Task 3: Badge plasmoid full — point 3 couleurs + tooltip

**Files:**
- Modify: `plasmoid/package/contents/ui/FullRepresentation.qml:275-283`

- [ ] **Step 1: Passer le point et le tooltip à 3 états**

Remplacer (dans le `Rectangle` du badge, l.275-283) :
```qml
                    color: fullRep.provider === "cuda" ? "#27ae60" : "#c0392b"
                    border.color: fullRep.provider === "cuda" ? "#1e8449" : "#922b21"
                    border.width: 1
                    PlasmaComponents.ToolTip {
                        text: fullRep.provider === "cuda"
                            ? i18n("Daemon running on GPU")
                            : i18n("Daemon running on CPU")
                    }
```
par :
```qml
                    color: fullRep.provider === "cuda" ? "#27ae60"
                         : fullRep.provider === "cpu"  ? "#c0392b"
                         : "#3498db"
                    border.color: fullRep.provider === "cuda" ? "#1e8449"
                                : fullRep.provider === "cpu"  ? "#922b21"
                                : "#21618c"
                    border.width: 1
                    PlasmaComponents.ToolTip {
                        text: fullRep.provider === "cuda"
                            ? i18n("Daemon running on GPU")
                            : fullRep.provider === "cpu"
                            ? i18n("GPU unavailable — running on CPU")
                            : i18n("Daemon running on CPU")
                    }
```

- [ ] **Step 2: Mettre à jour le commentaire d'en-tête** (l.18-19)

Remplacer :
```qml
    // ASR provider effectif depuis /dev/shm/.dictee_provider (via main.qml).
    // 'cuda' = badge vert | 'cpu'/'cpu-forced'/'cpu-only' = badge rouge.
```
par :
```qml
    // ASR provider effectif depuis /dev/shm/.dictee_provider (via main.qml).
    // 'cuda' = vert | 'cpu' = rouge (panne) | 'cpu-forced'/'cpu-only'/'cpu-int8' = bleu.
```

- [ ] **Step 3: Redéployer + vérif visuelle** (popup ouvert)

```bash
kpackagetool6 -u "$(pwd)/plasmoid/package"
setsid plasmashell --replace >/dev/null 2>&1 &
echo -n cuda     > /dev/shm/.dictee_provider   # point vert,  tooltip "on GPU"
echo -n cpu      > /dev/shm/.dictee_provider   # point rouge, tooltip "GPU unavailable"
echo -n cpu-int8 > /dev/shm/.dictee_provider   # point bleu,  tooltip "on CPU"
```
Expected: point vert/rouge/bleu + tooltips corrects en ouvrant le popup.

- [ ] **Step 4: Commit**

```bash
git add plasmoid/package/contents/ui/FullRepresentation.qml
git commit -m "feat(plasmoid): badge provider full — point 3 couleurs + tooltip panne"
```

---

### Task 4: Badge tray — émoji cercle 3 couleurs

**Files:**
- Modify: `dictee-tray.py:1520-1529`

- [ ] **Step 1: Ajouter le cercle bleu (CPU voulu) et réserver le rouge à la panne**

Remplacer :
```python
    def _provider_suffix(self):
        """Retourne un badge unicode coloré : 🟢 cuda, 🔴 cpu*, '' inconnu.
        Ajouté à la fin du label daemon (après ■) — pareil que le badge
        rond du plasmoid full representation.
        """
        if self.provider == "cuda":
            return " \U0001F7E2"  # 🟢 large green circle
        if self.provider in ("cpu", "cpu-forced", "cpu-only"):
            return " \U0001F534"  # 🔴 large red circle
        return ""
```
par :
```python
    def _provider_suffix(self):
        """Retourne un badge unicode coloré ajouté au label daemon :
        🟢 GPU (cuda) | 🔴 panne CPU (cpu = libs CUDA cassées) |
        🔵 CPU voulu (cpu-forced / cpu-only / cpu-int8). '' si inconnu.
        Le menu Qt n'affiche pas de lettre colorée → on garde des cercles
        (cohérent en COULEUR avec le badge plasmoid).
        """
        if self.provider == "cuda":
            return " \U0001F7E2"  # 🟢 GPU
        if self.provider == "cpu":
            return " \U0001F534"  # 🔴 panne (GPU indisponible)
        if self.provider in ("cpu-forced", "cpu-only", "cpu-int8"):
            return " \U0001F535"  # 🔵 CPU voulu
        return ""
```

- [ ] **Step 2: Vérifier `_provider_suffix` n'a pas d'autre dépendance au set `("cpu","cpu-forced","cpu-only")`**

Run: `grep -n '"cpu", "cpu-forced", "cpu-only"\|"cpu-forced", "cpu-only"' dictee-tray.py`
Expected: vérifier chaque occurrence — si une autre logique (ex. `_provider_suffix` ailleurs, tooltip) groupe `cpu` avec les CPU-voulus, l'aligner sur la nouvelle sémantique (`cpu` = panne à part). Documenter ce qui est trouvé.

- [ ] **Step 3: py_compile + redéploiement tray + vérif visuelle**

```bash
python3 -m py_compile dictee-tray.py && echo "PY_COMPILE OK"
pkill -f dictee-tray.py; setsid python3 dictee-tray.py >/dev/null 2>&1 &
echo -n cpu-int8 > /dev/shm/.dictee_provider   # menu daemon → suffixe 🔵
echo -n cpu      > /dev/shm/.dictee_provider   # → 🔴
echo -n cuda     > /dev/shm/.dictee_provider   # → 🟢
```
Expected: le label daemon du menu tray montre 🟢 / 🔴 / 🔵 selon la valeur.

- [ ] **Step 4: Commit**

```bash
git add dictee-tray.py
git commit -m "feat(tray): badge provider — 🔵 CPU voulu distinct du 🔴 panne"
```

---

### Task 5: Vérification E2E backend (GPU réel) + build release

**Files:** aucun (vérification)

- [ ] **Step 1: Build release CUDA correct** (flags obligatoires, met à jour les symlinks host)

Run: `cargo build --release --no-default-features --features "cuda,sortformer,load-dynamic" --bin transcribe-daemon`
Expected: build OK (le hook anti-build-nu laisse passer `load-dynamic`).

- [ ] **Step 2: Monter un modèle int8 de test** (copie du fp32 renommée en .int8 — ONNX ignore le nom)

```bash
SRC=/usr/share/dictee/tdt   # ou ~/.local/share/dictee/tdt
T=$(mktemp -d); cp "$SRC"/vocab.txt "$T"/
cp "$SRC"/encoder-model.onnx       "$T"/encoder-model.int8.onnx
cp "$SRC"/encoder-model.onnx.data  "$T"/encoder-model.int8.onnx.data 2>/dev/null || true
cp "$SRC"/decoder_joint-model.onnx "$T"/decoder_joint-model.int8.onnx
```

- [ ] **Step 2bis: Lancer le daemon sur ce dir int8, GPU présent**

```bash
ORT_DYLIB_PATH=/usr/lib/dictee/libonnxruntime.so DICTEE_TRANSCRIBE_SOCKET=/tmp/t-int8.sock \
  ./target/release/transcribe-daemon "$T" 2>&1 | head -6
```
Expected: log `[dictee] Parakeet int8 model — forcing CPU …` puis chargement OK (pas de tentative GPU, pas de crash). `cat /dev/shm/.dictee_provider` → `cpu-int8`.

- [ ] **Step 3: Non-régression fp32 → GPU**

```bash
ORT_DYLIB_PATH=/usr/lib/dictee/libonnxruntime.so DICTEE_TRANSCRIBE_SOCKET=/tmp/t-fp32.sock \
  ./target/release/transcribe-daemon "$SRC" 2>&1 | head -6
```
Expected: PAS de log « forcing CPU » ; `cat /dev/shm/.dictee_provider` → `cuda` (sur GPU dispo). Nettoyer : `rm -rf "$T" /tmp/t-*.sock`.

- [ ] **Step 4: Pas de commit** (vérification uniquement). Restaurer le daemon de service si besoin (`systemctl --user restart dictee.service`).

---

## Notes de séquencement

- Tasks 2-4 (UI) sont indépendantes l'une de l'autre ; Task 1 (backend) est indépendante des UI (la valeur `cpu-int8` est juste une string).
- **Push** non inclus (décision utilisateur au cas par cas). Cible **master** uniquement.
- **Phase 2 (hors plan)** : grisages « Parakeet précis » (VRAM < 4 Go) + switch GPU/CPU (int8 actif).
