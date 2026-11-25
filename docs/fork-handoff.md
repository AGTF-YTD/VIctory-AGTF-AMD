# Passation : ce qui manque et comment le faire

État au 2026-11-25. Pour la personne ou l'agent qui reprend ce fork sur la machine
de test actuelle. Lire aussi [fork-ray-tracing.md](fork-ray-tracing.md) et le
README (section du fork).

## 0. Mise à jour : seconde session du 2026-11-25

Résumé pour la reprise. Les sections suivantes restent valables sauf là où
celle-ci les corrige.

### Mesures sur la RX 6900 XT (scène de la prison, même machine)

| Profil | ms/image | fps | Remarques |
|--------|----------|-----|-----------|
| Défaut (aucun réglage) | ≈ 335 | 3,0 | stable 8 min |
| `VICTORY_RELAY=2` (ancien défaut de `run-fast.ps1`) | ≈ 550 | 1,8 | **perte du GPU** après ≈ 1 min dans le monde |
| late (`LATE_WAIT=3 WIDE_BACK CARD_BUFFERS_MIN_MB=1 CARD_BUFFERS_MB=1024`) | ≈ 197 | 5,1 | image identique |
| + `WIDE_REFRESH WIDE_MERGE JOIN_COPIES CARD_REHASH_RUNS` | ≈ 176 | 5,7 | |
| + `VICTORY_INDIRECT_WINDOW=1` (**profil `fast`, nouveau défaut**) | ≈ 160 | 6,2 | image identique |
| + `VICTORY_INDIRECT_WINDOW=2` (nouveau, voir plus bas) | ≈ 158 | 6,3 | points parasites sur un objet : pas dans le profil |
| + `VICTORY_CARD_WINDOWS_MB=4096` | ≈ 162 | 6,2 | aucun gain : la carte n'est pas limitée par le bus |
| + `VICTORY_DISPLAY_MODE=1920x1080` | ≈ 172 | 5,8 | aucun gain |

`run-fast.ps1` lance maintenant le profil `fast` par défaut (`-Mode relay`
reste disponible). Le build release n'injecte pas `VICTORY_KEYS` (diag
seulement) : il faut appuyer soi-même sur Entrée dans la fenêtre.

Où passe une image de 160 ms avec le profil `fast` :

- la carte travaille ≈ 110 ms ; dans la mesure par commande
  (`VICTORY_GPU_TIMING=1 VICTORY_D3D12_DRED=1`, build diag), les commandes
  du jeu font ≈ 111 ms, dont ≈ 22 ms pour deux programmes de tracé de
  rayons qui parcourent une structure jamais construite
  (`indirect_diffuse_lighting:CS_ScreenProbes_TraceRays_RayBinning_BVH_*`
  ≈ 16 ms, `sr_tracing:CS_RaytraceVBuffer_*` ≈ 6 ms) ;
- la carte attend ≈ 45-50 ms par image que le thread de soumission
  finisse ses copies (rafraîchissements par `ReadProcessMemory` et
  requêtes de surveillance d'écriture : ≈ 50 ms pour ≈ 155 Mo) ;
- le jeu met ≈ 50 ms après chaque présentation avant d'enregistrer, en
  parallèle du travail de la carte.

Pour atteindre 30 images/s il faut donc à la fois diviser le temps carte
par ≈ 4 (efficacité des shaders traduits, coût par commande) et supprimer
les copies (mémoire du jeu ouverte au GPU, `VICTORY_INPLACE`). Ni l'un ni
l'autre n'est un réglage.

### Changements de cette session

Traducteur :

1. `v_cvt_f32_f64` : conversion en arithmétique entière, arrondi au plus
   proche pair, dénormaux remis à zéro (`lower.rs`). Test GPU
   `v_cvt_f32_f64_rounds_to_nearest_even`.
2. `v_permlane16_b32` / `v_permlanex16_b32` : par `waveReadLaneAt`
   (`lower.rs`), comptés parmi les programmes inter-lanes.
3. Somme de f16 sur la wave là où toutes les lanes ne tournent pas
   (`half_sum`) : approximation f32 arrondie une fois (raccourci
   documenté). `compute_graph_ops:CS_TransposeVecMatMulAlignedOperation`
   se traduit : 14 dispatches par image n'étaient plus abandonnés.
4. `VICTORY_RAYS_MISS=1` (optionnel, dans la clé du cache) : chaque test
   de rayon répond « raté » sans lire de nœud. Économise ≈ 22 ms de carte,
   mais l'image devient délavée (voile lumineux) avec des blocs sur les
   personnages : **à ne pas activer**.

Bilan de traduction : compute 2 723 / 2 734 (au lieu de 2 720), tous
validés ; VS/PS et mesh inchangés.

GPU :

5. `VICTORY_INDIRECT_WINDOW=2` : fenêtres de bornage aussi pour les
   dispatches indirects et les shaders qui écrivent, fermées aux barrières
   et attentes du jeu (`draw.rs` `title_barrier`, appelée depuis
   `list.rs`). Gain minime et artefacts : laissé optionnel.
6. Diagnostics du constructeur de BVH :
   - `VICTORY_BVH_WRITEBACK=<hash>,...` : seuls ces programmes du
     constructeur recopient leurs écritures dans la mémoire du jeu, les
     autres sont en quarantaine (dichotomie) ;
   - les bits d'accès GPU des allocations `XMemVirtualAlloc` sont
     enregistrés (`memory.rs` `title_memory_access`) et la mémoire par
     adresse refuse les pages que le jeu n'a pas ouvertes au GPU
     (`VICTORY_BVH_CPU_PAGES=1` lève la règle).

### Constructeur de BVH : ce qui est établi

- Sans quarantaine, le jeu plante dans la première image où le
  constructeur tourne : le pointeur de données d'une table de hachage du
  CPU (title+0x4ffe63) est remplacé par des valeurs de type GPU (flottant
  −0,846 dans le mot haut). La recopie est exacte à l'octet : le GPU a
  bien écrit là.
- Ni la première ni la seconde moitié des 52 programmes, seule, ne le fait
  planter : c'est une combinaison (une valeur que le CPU relit, ou des
  adresses calculées par une étape à partir d'une autre).
- La table de hachage est dans une zone ouverte au GPU (bits 0x22000) : le
  jeu mélange objets CPU et données GPU, donc refuser les pages « CPU
  seulement » ne suffit pas.
- Les premières images du constructeur touchent des centaines de pages
  sans copie (lues à zéro, écritures perdues), y compris autour de
  0x10000 : les premières constructions calculent à partir de zéros.
- Avec la première moitié en recopie, l'image est surexposée puis
  incohérente (visages noirs, fond plat), et 0,3 fps.

Piste : la mémoire par adresse a besoin d'un accès direct du GPU à la
mémoire du jeu (tas ouvert sur la mémoire du jeu, `inplace.rs`), à la fois
pour que rien ne soit lu à zéro et pour supprimer les copies et
comparaisons par liste qui font les 0,3 fps.

### Shaders encore refusés en jeu

`PS_PuddleDetect` (2 en jeu, 40 au total : « a descriptor read only as
data », l'échec est signalé à l'export, loin du chargement fautif),
`water_shading:CS_TransmissionVolumetrics_Tiled*` (boucle sur les lanes
restantes que la simulation de section ne suit pas : `s_andn2_b64` sur une
copie d'exec puis `s_cbranch_scc1`), `ShallowWaterSim:CS_MinTimestepReduce`.

## 1. Machine et état de départ

- Ryzen 7 7800X3D, **Radeon RX 6900 XT** (16 Go, RDNA2, waves de 64 lanes
  natives ; adaptateur DXGI 0). L'iGPU du CPU et plusieurs écrans virtuels
  (Parsec, Virtual Desktop, Meta) sont aussi présents.
- Dump du jeu : `E:\GTADump` (déclaré dans `victory.toml`).
- Les chiffres du README viennent d'une RTX 4070 (waves de 32 lanes). Sur la
  6900 XT, **ne pas** mettre `VICTORY_HOST_MAX_WAVE=32` pour les bilans de
  traduction : plusieurs programmes ne passent que grâce au wave64.

Ce qu'on voit aujourd'hui :

| Étape | État |
|-------|------|
| Démarrage, menus, écran-titre vidéo | OK, 30 fps, vidéo fluide (corrigé, voir §2) |
| Entrée dans le monde (cinématique de la prison) | OK, environ 3-4 min après le lancement |
| Rendu du monde | Géométrie, textures et lumière directe OK ; **tout ce qui est à l'ombre est noir** (pas d'éclairage ray-tracé) |
| Framerate dans le monde | **≈ 2 fps** (build diag avec capture activée) |
| Ray tracing (`VICTORY_BVH_BUILDER=1`) | Tourne et éclaire, mais **éclats de triangles blancs** et ≈ 0,27 fps |
| « Murs transparents » signalés par l'utilisateur | **Non confirmés** : pas encore isolés dans une capture |

## 2. Ce qui a été changé pendant cette session

Tous les tests passent (`cargo test --release -p victory-shader` : 211 ;
`-p victory-gpu` : 110).

Traducteur de shaders (`crates/victory-shader`) :

1. **Lignes de signature à modes d'interpolation mélangés** :
   `emit/container.rs` `split_mixed_rows`, appelée dans `emit/shader.rs`
   `finish`. Les éléments entiers liés passent de la ligne `r` à `r + 16`,
   règle identique pour toutes les étapes (VS/MS en sortie, PS en entrée,
   GS des rectangles des deux côtés). Test :
   `integer_channels_leave_mixed_rows`.
2. **Ordre des éléments dans ISG1/OSG1** : tri par registre seul, stable,
   comme le fait le writer de DXC (`container.rs` `signature`).
3. **Sampler choisi par le flot de contrôle entre le heap et des samplers
   immédiats** (`PS_TexturedLit*`, `MST_DS_TerrainTransform`) :
   `emit/lower.rs` `descriptor_phi` renvoie aussi un phi de drapeau, et
   `handle` enregistre les alternatives dans `sampler_alts`. La lecture de
   texture est refaite par sampler avec `bitcode::Module::recall`, puis
   choisie canal par canal (DXIL interdit le `select` de handles).
4. **Moitié de registre 16 bits gardée au-dessus d'une moitié
   d'interpolation** (`v_fma_mixlo/hi_f16`) : l'ancienne valeur manquante
   vaut 0 (`lower.rs`, cas `v_fma_mix*`).
5. **SGPR qu'on croit être une entrée matérielle mais que le programme écrit
   lui-même** : lu comme 0 (`lower.rs` `inputs`). *Raccourci* documenté dans
   le code.
6. **POPS** (`src_pops_exiting_wave_id`, opérande 239) : lu comme 0, et le
   mot de collision vaut 0 grâce à la règle 5, donc l'attente est sautée.
   *Raccourci* : les pixels qui se chevauchent dans un même draw ne sont plus
   ordonnés.

Côté GPU (`crates/victory-gpu`) :

7. **Écran-titre qui « clippe » entre deux images** : la vidéo Bink est
   décodée dans un anneau de 3 jeux de textures en mémoire de vue. Le
   décodeur y écrit par une autre vue, que la garde ne voit pas, et le hash
   de secours ne passait qu'une frame sur 8. Correctif : `texture.rs`
   `Last::volatile`. Un changement que la garde a manqué rend la texture
   « volatile » : elle est hachée à chaque vérification, puis revient au
   rythme normal après `VOLATILE_CHECKS` (64) vérifications sans changement.
8. **Diagnostics seulement** (`device.rs`) : `VICTORY_DUMP_PIPELINES=<dir>`
   dumpe les descriptions `0x1c8`/`0x218` et les zones qu'elles désignent ;
   un journal compte les pipelines distincts (`unknown pipeline: a new one`).

Outils (`apps/victory`) :

- `VICTORY_FIND_CODE=<dir>` avec `translate` : nomme les conteneurs dont le
  code natif contient les 48 premiers octets d'un fichier du dossier.
- `VICTORY_DISASM_RAW=<fichier>` avec `shader-info` : désassemble un bloc de
  code GFX10 brut (`VICTORY_DISASM_WAVE64=1` pour le wave64).
- `run-fast.ps1` à la racine lance le build release avec les options de
  vitesse du fork (`-Mode relay|late|off`). Pas encore mesuré sur la 6900 XT.

Bilan de traduction sur tout le dump (wave64 natif) : VS/PS 14 223 émis sur
14 259, compute 2 720 sur 2 734, mesh 8 765 sur 8 765.

**Important** : le runtime n'utilise pas le validateur DXIL, il charge le
DXIL non signé. Seuls les échecs `emit:` et `resources:` retirent des draws
en jeu ; un échec `validator:` n'est qu'un défaut de conformité.

## 3. Ce qui manque, par priorité

### 3.1 Éclairage des zones d'ombre (le plus visible)

**Cause** : l'éclairage indirect et les ombres des lampes et du soleil sont
ray-tracés par le jeu, en compute (voir `fork-ray-tracing.md`). Sans le
constructeur de BVH, ces passes ne produisent rien, d'où le noir.

**Constat sur la 6900 XT** : avec `VICTORY_BVH_BUILDER=1
VICTORY_BVH_QUARANTINE=1`, le jeu log *« the ray-tracing structure builder
runs: all of its programs have host pipelines pipelines=53 »*, sans plantage
ni perte du GPU. Les scènes s'éclairent, mais :

- **de grands triangles blancs en éclats** apparaissent : des écritures du
  constructeur atterrissent sur des copies hôtes de tampons de géométrie (en
  quarantaine, elles restent dans les copies hôtes, que le rasterizer lit
  aussi) ;
- le jeu tombe à **≈ 0,27 fps**.

**Comment avancer :**

1. Trouver l'étape fautive. Le constructeur est tout ou rien
   (`pipeline.rs` `Builder`). Ajouter un mode diag qui, après chaque
   dispatch du constructeur, compare les plages de mémoire que ce dispatch a
   déclarées en écriture (root UAVs, mémoire par adresse dans
   `memory.rs`/`shadow.rs`) avec les copies hôtes de tampons de sommets et
   d'index. Journaliser le hash du programme qui écrit hors de sa plage.
   Pistes probables :
   - adresses 40 bits mal reconstruites dans `Lower::memory` (`lower.rs`) ;
   - écritures 8/16 bits ou atomiques sur une page sans copie hôte
     (« an access to a title page that has no host copy is lost », d'après
     la doc RT) ;
   - un compteur ou une taille que le jeu relit, alors que la quarantaine ne
     les recopie pas en mémoire du jeu, ce qui donne des offsets faux à
     l'étape suivante ;
   - différences wave64 dans les programmes qui échangent par lanes
     (`emit/wave.rs`).
2. Vérifier l'instruction de test de rayon émulée : ses tests sur GPU
   tournaient sur une carte wave32 (`emit/intersect_tests.rs`). Les relancer
   sur la 6900 XT.
3. Passer ensuite à la vitesse : mesurer le temps GPU par dispatch du
   constructeur et des programmes de tracé. Les copies de mémoire du jeu
   vers le GPU avant chaque dispatch sont le suspect n°1.
4. Les 5 programmes de tracé d'ombre (shadow-mask) qui ne se traduisaient
   pas d'après la doc RT passent tous en wave64 natif ; à confirmer en jeu.

**Alternative de secours**, si le RT reste hors de portée : repérer le
dispatch qui écrit le cache d'irradiance (le programme de shading du cache
est nommé dans la doc RT) et, quand le constructeur est éteint, remplir sa
sortie avec une lumière ambiante neutre. À faire derrière une option ; il
faut d'abord comprendre le format de la sortie (SH ? radiance ?), sinon
couleurs fausses.

### 3.2 « Murs transparents » (non confirmé)

Sur la frame +72 du monde (scène de rue de nuit), des enseignes flottent
dans le noir : façades non dessinées ou non éclairées, ce n'est pas tranché.
Méthode :

1. Capturer la frame avec `VICTORY_CAPTURE_FRAMES=<n>` et
   `VICTORY_DUMP_TARGETS=1`.
2. Lire `frame-<n>-ops.txt` : chercher les draws `dropped`, les draws sans
   pipeline hôte, et les cibles du G-buffer. Si les façades sont dans
   l'albedo du G-buffer, c'est de l'éclairage (§3.1) ; sinon, c'est un draw
   perdu.
3. Pendant une session complète, seuls 2 pixel shaders et 5 compute shaders
   ont été refusés à la traduction (`shader does not translate` dans le
   log) : commencer par eux.

### 3.3 Framerate (≈ 2 fps)

- Tester `run-fast.ps1 -Mode relay` et `-Mode late` sur la 6900 XT. Lire le
  temps par frame dans le titre de la fenêtre ou les lignes `the card's time
  by` du log.
- Le log `copystat` donne le temps d'enregistrement des listes et d'attente
  de la carte. Une frame mesurée enregistrait 72 004 appels de liste en
  4,5 s de threads cumulés : la préparation côté CPU (copies de mémoire du
  jeu, hachage de textures) est la première cible.
- `VICTORY_INPLACE` (mémoire du jeu ouverte comme heap graphique) n'en est
  qu'à son premier étage ; c'est la piste structurelle pour supprimer les
  copies.
- Surveiller le coût de `Last::volatile` (§2.7) en jeu : une texture
  volatile est hachée à chaque frame. Si une texture de jeu le reste en
  permanence, la limiter en taille.

### 3.4 Pipelines précompilés `0x1c8` / `0x218` (saccades, pas l'image)

- 8 251 pipelines distincts, **tous demandés dans la même seconde au
  démarrage** (frames 16 à 64), jamais pendant le jeu. Dans le code du jeu,
  à title+0x2477578 (`callq *0x1c8(%rax)`), un échec fait seulement passer à
  l'entrée suivante de la liste : c'est un préchauffage de cache. Les
  pipelines de jeu viennent ensuite des conteneurs DXIL via `create_stream`.
- Format observé de la description (mots de 64 bits) : w0 la root signature
  (un objet hôte) ; w1-w12 un premier groupe de 6 paires (adresse, taille) ;
  w33-w43 des pointeurs et des hashes (w38 = hash du pipeline, présent une
  fois dans une table de `shaders.rpf` vers 0x1029_0000-0x102B_6000) ;
  w44 un pointeur ; w45-w56 un second groupe de 6 paires.
- Chaque groupe contient, dans l'ordre : un bloc d'état (0x184 o), un bloc
  d'E/S (≈ 0xbc o, avec les noms de sémantiques comme « POSITION »), du
  code A (≈ 0x200 o), des métadonnées A (≈ 0xd0 o), du code B (≈ 0x200 o)
  et des métadonnées B (≈ 0xb0 o). Le code est du GFX10 précédé d'un
  en-tête de 36 octets (3 faux `v_nop` contenant des hashes) ; les exports
  sont déjà convertis au format de la cible.
- Ce code n'existe dans **aucun** conteneur de `shaders.rpf` (vérifié avec
  `VICTORY_FIND_CODE` ; les seules correspondances étaient du bourrage
  `s_code_end`).
- Pour l'implémenter : décoder les blocs de métadonnées en
  `victory_shader::NativeProgram` (`layout`, `used`, `io`, `wave64`,
  `vgprs`), retirer l'en-tête de 36 octets du code, puis passer par le
  chemin de traduction existant. Commencer par comparer les métadonnées
  avec le format FSSM documenté en tête de `native.rs`. Gain attendu :
  moins de compilation pendant le jeu.

### 3.5 Shaders qui ne se traduisent pas encore (bilan wave64)

| Nombre | Raison | Exemple | Piste |
|--------|--------|---------|-------|
| 195 | `resources: an address in an SGPR that is no root parameter` | `GS_VoxelizeGeneric*` | Vérifier d'abord que le jeu s'en sert en jeu (log `shader does not translate`). Étape géométrie ; suivre l'adresse dans `resource.rs` |
| 40 | `emit: a descriptor read only as data` | `PS_PuddleDetect*` | Flaques. Lire le mot du descripteur comme donnée (`resource.rs`, `lower.rs`) |
| 71 | `validator:` sortie mesh > 32 Ko | `MS_VS_Ped*Fire*` | Sans effet au runtime (pas de validation) ; réduire les maxima ou répartir les sorties si un driver plante |
| 5 | `emit: v_cvt_f32_f64` | eau, `CS_TransmissionVolumetrics*` | Pas de f64 dans le lowering : convertir à partir des deux mots en entiers (signe, exposant, mantisse, arrondi au plus proche pair) |
| 1 | `emit: v_permlanex16_b32` | eau | Lowering avec `waveReadLaneAt` comme les autres permutations (`lower.rs`, autour de `ds_swizzle`) |
| 3 | `validator: out of bound coord must be undef` | `PS_*DeferredTextured_AlphaClip` | Mettre `undef` aux coordonnées au-delà de la dimension de la texture |
| 3 | `validator:` interpolation mélangée (float lu à plat à côté de float interpolé) | `NORMAL (5,0)` | Étendre `split_mixed_rows` à ce cas, avec une règle identique dans les deux étapes |
| 2 | `emit: a wave sum of 16-bit floats where not every lane runs` | `compute_graph_ops` | `emit/wave.rs` |
| 1 | `emit: an opaque lane mask` | `PS_VoxelizeVisiblity` | `structure.rs` |
| 1 | `emit: a descriptor's address or format read as data` | `ShallowWaterSim` | comme PuddleDetect |

Bilan à relancer après chaque changement :

```bash
./target/release/victory.exe translate --validate > tally.txt
grep -E "emitted of|^ +[0-9]+  " tally.txt
```

`VICTORY_FAIL_DUMP=<dir>` garde 3 conteneurs par raison d'échec ;
`shader-info <dir> --disasm` les désassemble.

### 3.6 Autres manques connus (README)

Test de depth bounds ignoré (log `depth bounds test`), vraies requêtes GPU,
HDR et mise à l'échelle, atomiques 64 bits sur images, ≈ 24 Go de mémoire en
jeu, intérieur de la première pièce parfois absent après la cinématique.

## 4. Comment tester soi-même

Builds :

```bash
cargo build --release -p victory                               # target/release
cargo build --profile diag -p victory --features diagnostics   # target/diag (captures, touches)
cargo test --release -p victory-shader -p victory-gpu
```

Le cache de shaders est indexé sur le hash de l'exécutable : toute
recompilation l'invalide, et la première session est plus lente.

Aller jusqu'au monde et capturer (build diag) :

```bash
VICTORY_KEYS="95:Enter,110:Enter,125:Enter,140:Enter" \
VICTORY_CAPTURE=<dir> VICTORY_CAPTURE_WORLD=1 VICTORY_CAPTURE_WORLD_ALSO=100,150,200,300 \
timeout 585 ./target/diag/victory.exe run "E:/GTADump/game_scarlett_master.exe" --execute > log.txt 2>&1
```

- Le monde commence 3 à 4 minutes après le lancement ; le log dit *« the
  first frame of 500 draws or more »* avec son numéro de frame.
- La cinématique avance avec le temps, pas avec les frames : à des
  vitesses différentes, une même frame relative montre des plans
  différents.
- Le log contient des codes couleur ANSI : `sed 's/\x1b\[[0-9;]*m//g'`.
- `VICTORY_CAPTURE_FRAMES=a,b,c` capture des frames précises et écrit
  `frame-<n>-ops.txt` : chaque draw, dispatch, upload et soumission.
- Si le GPU est perdu (device removed), `crashes.log` est dans
  `%LOCALAPPDATA%\victory\data\7952987A\` ; les pertes s'affichent comme un
  écran noir bref sur tous les moniteurs.

Détecter un scintillement ou une boucle d'images (Python avec Pillow) :

```python
import sys, os
from PIL import Image, ImageChops, ImageStat
d, a, b = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
ims = {n: Image.open(f"{d}/frame-{n}.png").convert("L").resize((240, 135))
       for n in range(a, b + 1) if os.path.exists(f"{d}/frame-{n}.png")}
for n in sorted(ims):
    for k in (1, 2, 3):
        if n - k in ims:
            print(n, k, round(ImageStat.Stat(ImageChops.difference(ims[n], ims[n - k])).mean[0], 2))
```

Un écart nul à `k` = 3 avec des écarts non nuls à 1 et 2 voulait dire
« anneau de 3 tampons périmés » : c'était le bug de l'écran-titre.
