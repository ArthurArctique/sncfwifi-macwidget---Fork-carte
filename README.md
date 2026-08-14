# SNCFWifi — Widget barre de menus macOS 🚄

[![Build](https://github.com/antvgr/sncfwifi-macwidget/actions/workflows/build.yml/badge.svg)](https://github.com/antvgr/sncfwifi-macwidget/actions/workflows/build.yml)
[![GitHub Release](https://img.shields.io/github/v/release/antvgr/sncfwifi-macwidget?include_prereleases)](https://github.com/antvgr/sncfwifi-macwidget/releases/latest)
[![Coding with AI](https://img.shields.io/badge/Coding_with-AI-blue?style=flat)](https://github.com/nuclearrockstone/coding-with-ai-badge)

> **Fork de [antvgr/sncfwifi-macwidget](https://github.com/antvgr/sncfwifi-macwidget).**
> Le projet, son idée et l'essentiel du code sont d'[@antvgr](https://github.com/antvgr) ; ce dépôt
> n'ajoute que la carte du trajet, un correctif d'affichage dans la barre des menus et quelques
> retouches, détaillés dans [Nouveautés de ce fork](#nouveautés-de-ce-fork-). Le reste de ce README
> est celui de l'amont, corrigé là où ce fork change le comportement décrit.

Un widget pour la barre de menus macOS qui exploite l'API des portails WiFi embarqués pour afficher en temps réel les informations de votre trajet : gare suivante, vitesse, retard, données mobiles, etc.

Deux réseaux sont pris en charge : le **WiFi TGV Inoui** (`wifi.sncf`) et le **WiFi Eurostar** (`EurostarTrainsWiFi`, plateforme Icomera / `ombord.info`). L'opérateur est détecté automatiquement à partir du SSID.

<p align="center">
  <img src="img/GIF1.gif" width="45%" />
</p>

<p align="center">
  <em>TGV Inoui</em>
</p>

<!-- EMPLACEMENT CAPTURE EUROSTAR
     Déposer le GIF / la capture dans img/GIF_EUROSTAR.gif, puis décommenter ce bloc.

<p align="center">
  <img src="img/GIF_EUROSTAR.gif" width="45%" />
</p>

<p align="center">
  <em>Eurostar</em>
</p>
-->


---

## Téléchargement ⬇️

> ⚠️ **Ce fork ne publie pas de release.** Le lien ci-dessous et le cask Homebrew installent la
> version de l'amont, **sans** les ajouts listés plus bas. Pour les avoir, il faut compiler
> soi-même — voir [Compilation manuelle](#compilation-manuelle-).

> Pas besoin de compiler — téléchargez directement le `.zip` depuis la page **Releases**.

**[→ Télécharger la dernière version](https://github.com/antvgr/sncfwifi-macwidget/releases/latest)**

1. Décompressez le `.zip`
2. Glissez `SNCFWifi.app` dans votre dossier `Applications`
3. Double-cliquez pour lancer — l'icône apparaît dans la barre des menus

> **macOS bloque l'app** (non signée avec un certificat Apple Developer) lors du premier lancement. Deux options :
> - **Méthode simple** : faites un **clic droit → Ouvrir** sur `SNCFWifi.app`, puis cliquez **Ouvrir** dans la fenêtre d'avertissement
> - **Via le Terminal** : après avoir déplacé l'app dans `/Applications`, exécutez `xattr -cr /Applications/SNCFWifi.app` puis double-cliquez normalement

💡 **Lancement automatique au démarrage** : `Réglages Système > Général > Éléments de connexion` → cliquez `+` et ajoutez `SNCFWifi.app`.

---

## Installation via Homebrew 🍺

```bash
brew tap antvgr/sncfwifi https://github.com/antvgr/sncfwifi-macwidget
brew install --cask sncfwifi
```

Mise à jour vers la dernière version :

```bash
brew reinstall --cask sncfwifi
```

> L'app étant signée en ad-hoc, si macOS la bloque au premier lancement :
> `xattr -dr com.apple.quarantine /Applications/SNCFWifi.app` (ou clic droit → **Ouvrir**).

---

## Fonctionnalités 🛠

- **Détection automatique de l'opérateur** : le SSID détermine la plateforme interrogée (aucun réglage à faire)
- **Mode Démo** : serveur local pour tester les deux plateformes sans être dans un train

### TGV Inoui

- **Barre de menus** : affiche la prochaine gare, le temps restant, la vitesse et le retard éventuel en rotation
- **Menu déroulant** : numéro de train, liste des arrêts avec progression, consommation de données WiFi
- **Retard** : affichage tournant `⚠ +5min · Régulation du trafic` quand le train est en retard
- **Notification avant arrivée** : alerte 5, 10 ou 15 min avant la gare choisie
- **Carte du trajet** *(ce fork)* : tracé, arrêts et position du train en direct, dans le panneau

### Eurostar

- **Barre de menus** : vitesse et données restantes (`224 km/h · 983 Mo`), jauge de quota
- **Menu déroulant** : nom de la rame, vitesse, détail de la connectivité sol↔train (génération
  réseau, nombre de modems actifs, signal en dBm, opérateurs mobiles traversés, débit maximal),
  nombre d'utilisateurs connectés et consommation de données

> La plateforme Icomera n'expose **ni numéro de train, ni desserte, ni destination, ni retard, ni
> heure d'arrivée**. La timeline des arrêts, le sélecteur de gare d'arrivée et la notification
> avant arrivée sont donc masqués à bord d'un Eurostar.

---

## Nouveautés de ce fork ✨

### Carte du trajet 🗺️

Le bouton **Carte du trajet** remplace le contenu du panneau par une carte **MapKit** — pas une
fenêtre à part. Le fond `mutedStandard` est celui qu'Apple destine aux données superposées, et le
mode sombre suit le système.

- **Tracé exact** depuis `train/graph`, arrêts cliquables depuis `train/details`
- **Position en direct** : `train/gps` est sondé une fois par seconde, et entre deux relevés le
  marqueur avance seul le long des rails à la vitesse annoncée. Le relevé est projeté sur le tracé,
  puis un filtre résorbe l'écart à l'arrivée du suivant — le train suit donc la voie, pas une
  droite entre deux points.
- **Zoom au défilement vertical à deux doigts**, ancré sous le curseur. MapKit n'y proposait que le
  pincement.
- **Suivre le train** : zoome dessus puis le maintient au centre, image par image.
- **Cadrage conservé** entre deux ouvertures de la carte.

Le sondage à haute fréquence ne tourne que tant que la carte est affichée. Le coût machine est
négligeable ; en revanche les tuiles Apple consomment le **quota data du WiFi du train** — c'est le
premier affichage d'une zone qui coûte, ensuite elles sont en cache.

### Dénivelé positif du trajet ⛰️

Chaque gare de la desserte affiche le **dénivelé positif cumulé depuis le départ**, et le panneau
résume celui atteint à la position actuelle. Sur un Toulouse → Lyon : 70 m à Carcassonne, 282 m à
Nîmes, 1 582 m à l'arrivée.

> ⚠️ **C'est une estimation, et elle dépend d'une convention.** L'API du train ne fournit aucune
> altitude en dehors de la position instantanée : le tracé de `train/graph` est en deux dimensions
> et les arrêts n'en portent pas. Le profil est donc reconstitué avec le **RGE ALTI de l'IGN**
> (Géoplateforme), interrogé une fois par trajet — trois requêtes, environ 150 Ko.

Deux précautions rendent le chiffre défendable :

- le tracé est **rééchantillonné à pas constant** (200 m), pour que la densité variable du graphe
  SNCF ne décide pas du résultat ;
- le profil est **lissé sur 2 km**, parce que le RGE ALTI donne l'altitude du *sol* et non celle de
  la *voie* : sur une LGV, le train franchit les vallées en viaduc et les collines en tranchée.

Mesuré sur 29 km de LGV réelle, le profil brut donnait 244 m de dénivelé là où le GPS du train en
relevait 69 — un facteur 3,5. Après lissage à la même échelle, les deux sources concordent à 5 %
près. Le dénivelé positif reste une grandeur dépendante de l'échelle : le même trajet donne 1 998 m
avec une fenêtre de 1 km, 1 584 m à 2 km, 1 151 m à 5 km.

C'est le seul appel de l'app à un service extérieur au train, en dehors des tuiles de la carte ; les
coordonnées du trajet sont envoyées à l'IGN.

### Barre des menus visible sur les Mac à encoche 🩹

> Ce n'est pas un défaut introduit ici. Le comportement existe dans l'amont, et dans à peu près
> toute app de barre des menus qui ne réserve pas sa position — il ne se déclenche que sur un Mac
> à encoche dont la barre est déjà bien remplie. Le correctif tient dans un seul commit
> ([`1804ad1`](https://github.com/ArthurArctique/sncfwifi-macwidget---Fork-carte/commit/1804ad1)),
> volontairement isolé du reste pour pouvoir être proposé à l'amont tel quel.

Sans position enregistrée, macOS pose un nouvel élément au premier emplacement libre en partant de
la droite. Quand la barre est chargée, sur un MacBook à encoche, cet emplacement tombe **sous
l'encoche** : l'élément existe et reste cliquable, mais il est invisible, et le panneau semble
surgir de la caméra. Mesuré sur un 13 pouces avec une sonde neutre, sans code du projet : encoche
de x 646 à 825, emplacement attribué à x 770–808. Aucune largeur d'icône n'y échappe, même un carré
de 22 pt y tombe.

L'élément réserve désormais sa place. Le déplacer avec **⌘ + glisser** reste prioritaire : macOS
mémorise alors votre choix. Une trace au démarrage signale le cas où il finit malgré tout masqué :

```bash
log show --last 5m --predicate 'process == "SNCFWifi"'
```

### Libellé des gares accordé 🚉

« En gare **du** Mans » au lieu de « En gare de Le Mans », « En gare **des** Aubrais » au lieu de
« En gare de Les Aubrais ». L'abréviation d'un nom long ne coupe plus sur son article : « Les
Aubrais - Orléans » donne « En gare des Aubrais ».

### Serveur de démo qui roule pour de vrai 🧪

Il servait une position fixe et trois arrêts reliés en ligne droite. Il simule maintenant un
Paris → Lyon → Marseille suivant approximativement la LGV Sud-Est (343 points), et fait avancer la
position le long de ce tracé à la vitesse réglée dans le panneau démo — de quoi vérifier la carte
sans être à bord.

---

## Logos des compagnies 🎨

L'en-tête du panneau peut afficher le **logo de la compagnie** à la place de l'icône 🚋 et du nom
en toutes lettres (seul le numéro de train reste à côté). Les logos ne sont pas fournis dans le
dépôt : déposez-les vous-même dans `Resources/Logos/`, `build.sh` les embarque automatiquement.

| Fichier | Rôle |
|---|---|
| `logo-sncf.png` | Logo TGV INOUI |
| `logo-eurostar.png` | Logo Eurostar |
| `logo-<compagnie>@2x.png` | Variante Retina (facultative) |
| `logo-<compagnie>-dark.png` | Variante mode sombre (facultative) |

PNG à fond transparent (hauteur utile ~40 px) ou PDF vectoriel. **Le SVG n'est pas pris en
charge** : AppKit ne sait pas le charger et le projet compile sans *asset catalog* Xcode.

Tout est facultatif : sans fichier, l'en-tête retombe sur l'icône 🚋 teintée et le nom de la
compagnie. Voir [`Resources/Logos/README.md`](Resources/Logos/README.md) pour le détail.

---

## Prérequis ⚙️

- macOS 11 (Big Sur) ou plus récent — Apple Silicon et Intel (binaire universel)
- Connexion au WiFi d'un train pris en charge pour que l'API réponde :
  `_SNCF_WIFI_INOUI`, `OUIFI`, `SNCF_WIFI_INTERCITES`, `WIFI_SNCF`, `_WIFI_LYRIA` ou `EurostarTrainsWiFi`
- *(pour compiler)* Xcode Command Line Tools (`xcode-select --install`)

---

## Compilation manuelle 🔨

Un script bash compile et empaquète le projet en `.app` :

```bash
chmod +x build.sh
./build.sh
open SNCFWifi.app
```

💡 **Démarrage automatique** : `Réglages Système > Général > Éléments de connexion > ajouter SNCFWifi.app`

---

## Mode Démo via serveur local 🧪

Permet de simuler un trajet sans connexion au WiFi du train.

1. Lancer le serveur :
   ```bash
   chmod +x start_demo_server.sh
   ./start_demo_server.sh
   ```
2. Ouvrir le panneau de configuration :
   - dans l'app : **Ouvrir le panneau Démo**
   - ou directement : `http://127.0.0.1:8787`
3. Activer **Mode Démo** dans l'app.
4. Choisir la plateforme à simuler : menu **🐞 → Opérateur simulé → TGV INOUI / Eurostar**.
   Le serveur sert les deux jeux d'endpoints en permanence, ce réglage décide lequel est interrogé.

Endpoints simulés — TGV Inoui (JSON) :
| Endpoint | Description |
|---|---|
| `GET /router/api/train/graph` | Tracé GeoJSON exact du trajet prévu |
| `GET /router/api/train/gps` | Position GPS, vitesse en m/s |
| `GET /router/api/train/progress` | Progression du trajet |
| `GET /router/api/train/details` | Détails (arrêts, retard, numéro) |
| `GET /router/api/bar/attendance` | Affluence au bar |
| `GET /router/api/connection/statistics` | Qualité WiFi et appareils connectés |
| `GET /router/api/connection/status` | Consommation données (kB) |

Endpoints simulés — Eurostar (JSONP, réponses enveloppées dans `( … );`) :
| Endpoint | Description |
|---|---|
| `GET /api/jsonp/system/` | Identité de la rame (`system_name`) |
| `GET /api/jsonp/connectivity/` | Liaisons sol↔train : modems, technologie, RSSI, opérateurs |
| `GET /api/jsonp/users/` | Utilisateurs connectés / total |
| `GET /api/jsonp/user/` | Consommation et quota de la session (octets), débits max |
| `GET /api/jsonp/position/` | Position GPS, vitesse en m/s, cap, altitude |

> Les deux plateformes expriment la **vitesse en m/s** et l'**altitude en mètres**. Les volumes de
> données sont en **kB** côté SNCF et en **octets** côté Icomera.

Le trajet simulé est un Paris → Lyon → Marseille : la position avance le long du tracé à la vitesse
réglée dans le panneau démo, ce qui exerce aussi la carte.

---

## Tracer le trajet en Python 🐍

Le script `scripts/plot_train_route.py` trace le GeoJSON de `/router/api/train/graph`, ajoute la
position et la vitesse de `/router/api/train/gps`, puis marque les gares issues de
`/router/api/train/details`.

Depuis le WiFi du train :

```bash
python3 scripts/plot_train_route.py --output /tmp/train-route.png
```

Le fond OpenStreetMap est tenté automatiquement, mais le tracé fonctionne aussi sans fond externe :

```bash
python3 scripts/plot_train_route.py --no-basemap
```

Pour rejouer un instantané hors connexion, fournir les JSON sauvegardés avec `--graph-file`,
`--gps-file` et éventuellement `--details-file`.

---

## Contributeurs 🙌

| | |
|---|---|
| [@antvgr](https://github.com/antvgr) | Auteur du projet d'origine — l'idée, l'app, les deux plateformes |
| [@FlorianCasse](https://github.com/FlorianCasse) | Cask Homebrew (amont) |
| [@ArthurArctique](https://github.com/ArthurArctique) | Ce fork : carte du trajet, correctifs |
| **Claude** (Anthropic) | Co-auteur du code de ce fork — carte MapKit, correctif de l'encoche, libellé des gares, serveur de démo |

---

## Développé avec l'IA 🤖

Ce projet a été développé en grande partie avec l'aide de l'Intelligence Artificielle.

Les commits de ce fork portent un `Co-Authored-By: Claude` quand le code a été écrit avec
[Claude Code](https://claude.com/claude-code) — c'est-à-dire pour tout sauf
`scripts/plot_train_route.py`, issu d'une session avec un autre assistant.

![Claude](https://cwab.nuclearrockstone.xyz/api/badge?name=claude&theme=dark)
