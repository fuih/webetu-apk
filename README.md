# WebEtu Resto — Application Android (Flutter)

Application Android conçue avec Flutter pour automatiser la réservation quotidienne des repas universitaires sur **WebEtu (PROGRES / ONOU)**.

---

## Fonctionnalités

### Connexion PROGRES & ONOU
- Authentification avec votre matricule BAC et votre mot de passe PROGRES.
- Option **« Se souvenir de moi »** : vos identifiants restent enregistrés uniquement en local sur votre téléphone (aucun serveur tiers).
- Récupération automatique de vos informations étudiantes (DIA, wilaya, résidence).

### Onglet « Auto » — Réservation automatique
- **Activation en un geste** : un seul interrupteur active la réservation quotidienne en arrière-plan via Android WorkManager.
- **Choix des repas** : sélection libre entre Petit-déjeuner (فطور), Déjeuner (غداء) et Dîner (عشاء).
- **Jours actifs** : choix des jours de la semaine (du dimanche au jeudi par défaut).
- **Choix du restaurant** : liste des restaurants universitaires disponibles pour votre compte, avec recherche en français et en arabe.
- **Gestion du hors-ligne** : si le téléphone n'a pas de connexion à l'heure prévue, la tâche attend automatiquement le retour du Wi-Fi ou de la 4G pour effectuer la réservation.
- **Réservation immédiate** : bouton dédié pour lancer une réservation tout de suite sans attendre le prochain passage automatique.

### Onglet « Historique » — Suivi des réservations
- Compteur de repas réservés et heure de la dernière synchronisation.
- Filtres rapides (*Tous*, *Réservés*, *À vérifier*).
- Liste regroupée par date (*Aujourd'hui*, *Demain*, etc.) avec possibilité d'annuler les réservations encore modifiables.

---

## Remarque importante (Réseau)

Les serveurs PROGRES / ONOU bloquent les connexions provenant d'adresses IP étrangères. L'application doit donc être utilisée depuis une connexion algérienne (Wi-Fi local ou 4G), sans VPN actif.

---

## Compiler l'APK

Prérequis : [Flutter SDK](https://docs.flutter.dev/get-started/install) et Android SDK installés.

```bash
flutter pub get

# APK léger ARM64 (~19 Mo — recommandé pour la majorité des smartphones)
flutter build apk --split-per-abi

# Ou APK universel (~52 Mo — compatible toutes architectures)
flutter build apk --release
```

Les fichiers générés se trouvent dans :
- `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`
- `build/app/outputs/flutter-apk/app-release.apk`

---

## Installation sur Android

1. Transférez le fichier `.apk` sur votre téléphone.
2. Ouvrez-le depuis le gestionnaire de fichiers.
3. Autorisez l'installation d'applications provenant de cette source si Android vous le demande.
4. Installez l'application, connectez-vous avec vos identifiants WebEtu, choisissez votre restaurant et activez la réservation automatique.
