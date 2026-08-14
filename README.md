# SNCFWifi — Widget barre de menus macOS 🚄

[![Build](https://github.com/antvgr/sncfwifi-macwidget/actions/workflows/build.yml/badge.svg)](https://github.com/antvgr/sncfwifi-macwidget/actions/workflows/build.yml)
[![GitHub Release](https://img.shields.io/github/v/release/antvgr/sncfwifi-macwidget?include_prereleases)](https://github.com/antvgr/sncfwifi-macwidget/releases/latest)
[![Coding with AI](https://img.shields.io/badge/Coding_with-AI-blue?style=flat)](https://github.com/nuclearrockstone/coding-with-ai-badge)

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

### Eurostar

- **Barre de menus** : vitesse et données restantes (`224 km/h · 983 Mo`), jauge de quota
- **Menu déroulant** : nom de la rame, vitesse, détail de la connectivité sol↔train (génération
  réseau, nombre de modems actifs, signal en dBm, opérateurs mobiles traversés, débit maximal),
  nombre d'utilisateurs connectés et consommation de données

> La plateforme Icomera n'expose **ni numéro de train, ni desserte, ni destination, ni retard, ni
> heure d'arrivée**. La timeline des arrêts, le sélecteur de gare d'arrivée et la notification
> avant arrivée sont donc masqués à bord d'un Eurostar.

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

Depuis le panneau du train, le bouton **Carte du trajet** remplace le contenu du popover par une
carte MapKit : le tracé prévu vient de `train/graph`, les arrêts de `train/details`, et la position
de `train/gps`, sondée une fois par seconde. Entre deux relevés, le marqueur avance tout seul le
long du tracé à la vitesse annoncée, ce qui donne un déplacement continu plutôt qu'un saut par
seconde. Le sondage ne tourne que pendant que la carte est affichée.

Le serveur de démo simule un Paris → Lyon → Marseille : la position avance le long du tracé à la
vitesse réglée dans le panneau démo, de quoi vérifier la carte sans être à bord.

## Carte du trajet en Python 🗺️

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

## Développé avec l'IA 🤖

Ce projet a été développé en grande partie avec l'aide de l'Intelligence Artificielle.

![Claude](https://cwab.nuclearrockstone.xyz/api/badge?name=claude&theme=dark)
