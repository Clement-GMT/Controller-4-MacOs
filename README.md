# Controller 4 MacOs

Application de connexion pour trois modèles de manettes sur Mac. Le carrousel 3D se parcourt au trackpad, à la souris ou avec les flèches.

| Manette | Connexion |
| --- | --- |
| Xbox One première génération | USB · 045E:02DD |
| SCUF Valor Pro | USB · 1B1C:3A03 |
| Joy-Con 2 gauche et droit | Bluetooth · 057E:2067 et 057E:2066 |

Les Joy-Con 2 peuvent être utilisés seuls ou réunis en une manette. L’app affiche leur niveau de batterie séparément. Lorsque le pilote fournit la tension en millivolts, l’app affiche une estimation par paliers de 5 % avec le signe **≈**. L’info-bulle donne la tension lue dans le rapport Bluetooth. La tension varie notamment avec la charge, l’activité et la température. [Format des rapports Joy-Con 2](https://github.com/novakpetya/linux-switch2/blob/main/PROTOCOL.md#battery-voltage)

## Installation

- Le DMG fourni cible les Mac Apple Silicon sous macOS 15 ou ultérieur.
- Glisse **Controller 4 MacOs** dans **Applications**.
- Installe [OpenJoystickDriver 0.6.0-alpha.2](https://github.com/xsyetopz/OpenJoystickDriver/releases/tag/0.6.0-alpha.2) dans **Applications**. Ouvre-le et accorde les autorisations de surveillance de l’entrée, d’accessibilité et de Bluetooth quand macOS les demande.
- Le DMG fourni contient une application signée ad hoc. Pour une application téléchargée et bloquée par Gatekeeper, macOS permet une ouverture ponctuelle depuis **Réglages Système → Confidentialité et sécurité**. [Guide Apple](https://support.apple.com/fr-fr/guide/mac-help/mh40616/mac)

## Jouer

1. Sélectionne ta manette. Pour les Joy-Con 2, maintiens **SYNC** sur chaque manette déconnectée jusqu’au défilement des voyants.
2. Choisis **Automatique**, puis **Activer le pont**. Le profil suit le jeu au premier plan. Les profils fixes **macOS et Safari** et **Steam et SDL** servent aux jeux qui détectent la manette à leur démarrage. Pour le cloud Xbox, ouvre Safari.
3. Laisse l’application ouverte pendant que tu joues. Le bouton **Tester** mesure les entrées via Game Controller de macOS. En profil Steam/SDL fixe, tu peux aussi tester dans les paramètres de Steam.
4. **Diagnostic** vérifie le transport sélectionné. Le journal peut être copié depuis l’application.

Le jeu doit prendre en charge les manettes. Si une app ouvre une manette uniquement à son démarrage, active le pont et choisis son profil avant de l’ouvrir. Le pont utilise OpenJoystickDriver pour publier les manettes virtuelles. Le mode USB direct de l’Xbox One peut désactiver son extension Xbox USB si elle réserve déjà le périphérique.

## Compiler et publier

Utilise Xcode ou les outils Xcode en ligne de commande, puis exécute les commandes suivantes à la racine du projet.

    ./scripts/build.sh

Le script crée le DMG dans le dossier dist. Pour signer avec une identité Developer ID Application du trousseau, exécute la commande suivante.

    XBOX_BRIDGE_SIGN_IDENTITY='Developer ID Application: Votre nom (TEAMID)' ./scripts/build.sh

Pour une release GitHub avec notarisation, soumets le DMG à Apple via xcrun notarytool, agrafe le ticket avec xcrun stapler et joins le fichier à la release GitHub. [Notarisation Apple](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) · [Releases GitHub](https://docs.github.com/fr/repositories/releasing-projects-on-github/managing-releases-in-a-repository)

Les dépendances distribuées séparément restent sous leur propre licence. [OpenJoystickDriver](https://github.com/xsyetopz/OpenJoystickDriver)
