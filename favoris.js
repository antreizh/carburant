// Favorites de secours : communes et stations favorites reprises automatiquement
// quand la mémoire de l'application est vide (données du navigateur effacées, réinstallation).
//
// Pour les mettre à jour : dans l'application, Paramètres → Sauvegarde des favorites → « Copier le code »,
// puis remplacez le code entre guillemets ci-dessous et publiez ce fichier sur GitHub.
window.FAVORIS = "# Alertes par e-mail quand une station favorite sort d'une rupture temporaire du carburant favori.
# Vérification toutes les 30 minutes (les horaires GitHub peuvent avoir quelques minutes de retard).
name: Alertes fin de rupture

on:
  schedule:
    - cron: "*/30 * * * *"
  workflow_dispatch:
    inputs:
      test:
        description: "Envoyer un e-mail de test"
        type: boolean
        default: false

permissions:
  contents: write   # pour enregistrer alertes-etat.json entre deux vérifications

concurrency:
  group: alertes
  cancel-in-progress: false

jobs:
  verifier:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Vérifier les stations favorites
        shell: pwsh
        run: ./alertes.ps1
        env:
          SMTP_USER: ${{ secrets.SMTP_USER }}
          SMTP_PASSWORD: ${{ secrets.SMTP_PASSWORD }}
          MAIL_TO: ${{ secrets.MAIL_TO }}
          SMTP_HOST: ${{ secrets.SMTP_HOST }}
          SMTP_PORT: ${{ secrets.SMTP_PORT }}
          APP_URL: ${{ secrets.APP_URL }}
          TEST_MAIL: ${{ inputs.test }}

      - name: Enregistrer l'état des ruptures
        run: |
          if [ -n "$(git status --porcelain -- alertes-etat.json)" ]; then
            git config user.name "github-actions[bot]"
            git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
            git add alertes-etat.json
            git commit -m "Alertes : état des ruptures"
            git push
          fi
";
