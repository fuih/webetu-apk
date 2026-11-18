# 📱 WebEtu Resto — Application Android (Flutter)

Application mobile Android native (Flutter) pour l'automatisation de la réservation des repas universitaires **WebEtu (PROGRES)** et **ONOU** (Restauration Universitaire).

---

## ✨ Fonctionnalités principales

1. **🔐 Connexion PROGRES & ONOU** :
   - Connexion avec votre Matricule BAC et mot de passe PROGRES.
   - Option « Se souvenir de moi » avec sauvegarde locale uniquement sur votre appareil.
   - Détection automatique de votre contexte étudiant (DIA, Wilaya, Résidence).

2. **⚙️ Onglet « Auto » (Pilote automatique)** :
   - **Réservation automatique en arrière-plan** : Un bouton unique active la tâche quotidienne via Android WorkManager.
   - **Choix des repas** : Petit-déjeuner (`فطور`), Déjeuner (`غداء`), Dîner (`عشاء`).
   - **Jours de la semaine** : Sélection personnalisable des jours actifs (par défaut du dimanche au jeudi).
   - **Sélecteur de restaurant** : Liste en direct des restaurants universitaires rattachés à votre compte avec recherche (FR / AR).
   - **Résilience hors-ligne** : Si le téléphone n'a pas de connexion internet au moment prévu, Android met la tâche en attente et la déclenche automatiquement dès le retour du réseau (Wi-Fi ou 4G).
   - **Action immédiate** : Bouton pour lancer une réservation manuelle instantanée.

3. **📋 Onglet « Historique » (Vos réservations)** :
   - Résumé mensuel du nombre de repas réservés et heure de dernière synchronisation.
   - Filtres rapides (*Tous*, *Réservés*, *À vérifier*).
   - Liste groupée par date (*Aujourd'hui*, *Demain*, etc.) avec indicateur de repas et possibilité d'annuler les repas encore modifiables (`candelete`).

---

## 🛠️ Compiler l'APK depuis les sources

Prérequis : [Flutter SDK](https://docs.flutter.dev/get-started/install) et Android SDK installés.

```bash
flutter pub get

# Version optimisée légère (ARM64, ~19 Mo — recommandée)
flutter build apk --split-per-abi

# Ou version universelle compatible toutes architectures (~52 Mo)
flutter build apk --release
```

Les fichiers générés se trouveront dans :
- `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`
- `build/app/outputs/flutter-apk/app-release.apk`

---

## 📲 Installer l'APK sur Android

1. Transférez le fichier `.apk` compilé sur votre smartphone.
2. Ouvrez-le depuis votre gestionnaire de fichiers.
3. Si Android le demande, autorisez l'installation depuis cette source.
4. Appuyez sur **Installer**, puis connectez-vous avec vos identifiants WebEtu.
