# Controller 4 MacOs · v2.0.0

## Description du dépôt

Connecte tes manettes Xbox One, SCUF Valor Pro et Joy-Con 2 sur Mac. Carrousel 3D, profils macOS et Steam/SDL, batterie des Joy-Con et test des entrées.

## Notes de version GitHub

Controller 4 MacOs réunit trois manettes dans une app pour les Mac Apple Silicon sous macOS 15 ou ultérieur.

- Fais défiler les modèles 3D au trackpad, à la souris ou avec les flèches.
- Branche une Xbox One de première génération (045E:02DD) ou une SCUF Valor Pro (1B1C:3A03) en USB. Connecte les Joy-Con 2 gauche et droit en Bluetooth et joue avec les deux comme une seule manette.
- Le mode **Automatique** suit le jeu au premier plan. Les profils fixes **macOS et Safari** et **Steam et SDL** sont disponibles pour les jeux qui détectent les manettes à leur démarrage.
- Consulte séparément la batterie du Joy-Con gauche et du droit. Le signe **≈** indique une estimation, calculée à partir de la tension lue.
- Vérifie les sticks, boutons et gâchettes dans **Tester**, puis copie le journal depuis **Diagnostic** si la connexion pose problème.

### Installer

1. Télécharge **Controller-4-MacOs-2.0.0-arm64.dmg** depuis les fichiers de la release.
2. Glisse **Controller 4 MacOs** dans **Applications**.
3. Installe et ouvre [OpenJoystickDriver 0.6.0-alpha.2](https://github.com/xsyetopz/OpenJoystickDriver/releases/tag/0.6.0-alpha.2), puis accorde les autorisations macOS demandées.
4. Choisis ta manette dans **Controller 4 MacOs**, clique sur **Activer le pont** et garde l’app ouverte pendant que tu joues.

Cette version est signée ad hoc. macOS peut demander une ouverture ponctuelle depuis **Réglages Système → Confidentialité et sécurité**. [Guide Apple](https://support.apple.com/fr-fr/guide/mac-help/mh40616/mac)
