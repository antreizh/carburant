# Alertes « fin de rupture » pour Ma station service Éco.
#
# Lancé toutes les 30 minutes par GitHub Actions (.github/workflows/alertes.yml) :
#  1. lit les stations favorites et le carburant favori dans favoris.js ;
#  2. interroge le flux officiel prix-carburants pour ces stations ;
#  3. envoie un e-mail quand une station passe de « rupture temporaire » à « disponible » ;
#  4. enregistre l'état dans alertes-etat.json pour la vérification suivante.
#
# Variables d'environnement (secrets GitHub) : SMTP_USER, SMTP_PASSWORD, MAIL_TO,
# et en option SMTP_HOST (défaut smtp.gmail.com), SMTP_PORT (défaut 587), APP_URL.
# Sans SMTP_USER / SMTP_PASSWORD, l'e-mail est seulement affiché (essai à blanc).
# TEST_MAIL=true envoie un e-mail de test avec l'état actuel des stations suivies.

$ErrorActionPreference = 'Stop'

# Toute erreur est affichée en clair dans les « Annotations » de GitHub Actions, avec une piste de solution
trap {
  $e = $_.Exception; $m = $e.Message
  while ($e.InnerException) { $e = $e.InnerException; $m += ' | ' + $e.Message }
  $hint = switch -Regex ($m) {
    'Authentication|5\.7\.|credentials|Username and Password' { " → Gmail refuse la connexion : vérifiez les secrets SMTP_USER (adresse Gmail complète) et SMTP_PASSWORD (mot de passe d'application de 16 lettres, sans espaces, créé avec ce même compte)." ; break }
    'favoris\.js' { ' → Vérifiez favoris.js : la ligne doit être window.FAVORIS = "MSE1:…"; avec les guillemets et le point-virgule.' ; break }
    'names\.js|Could not find|introuvable' { ' → Un fichier manque à la racine du dépôt (favoris.js, names.js, alertes.ps1 au même niveau que index.html).' ; break }
    'resolve|Name or service|timed out|délai' { ' → Problème réseau passager : la prochaine vérification réessaiera.' ; break }
    default { '' }
  }
  Write-Host ("::error title=Alertes::" + ($m + $hint) -replace "`r?`n", ' ')
  exit 1
}

$Root = $PSScriptRoot
$Api = 'https://data.economie.gouv.fr/api/explore/v2.1/catalog/datasets/prix-des-carburants-en-france-flux-instantane-v2/records'
$Fuels = [ordered]@{ gazole = 'Gazole'; e10 = 'SP95-E10'; sp98 = 'SP98'; sp95 = 'SP95'; e85 = 'E85'; gplc = 'GPLc' }
$StateFile = Join-Path $Root 'alertes-etat.json'

# --- Favorites : code MSE1 de favoris.js (même format que la sauvegarde de l'application) ---
function Read-Favoris {
  $txt = [IO.File]::ReadAllText((Join-Path $Root 'favoris.js'))
  # Code cherché n'importe où dans le fichier (guillemets abîmés ou retours à la ligne tolérés) ; le dernier trouvé l'emporte
  $codes = [regex]::Matches(($txt -replace '\s', ''), 'MSE1:([A-Za-z0-9+/]+={0,2})')
  if (-not $codes.Count) { throw 'favoris.js : code de sauvegarde introuvable (aucun texte commençant par MSE1:).' }
  try { $data = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($codes[$codes.Count - 1].Groups[1].Value)) | ConvertFrom-Json }
  catch { throw 'favoris.js : le code de sauvegarde est incomplet ou abîmé. Recopiez-le depuis Paramètres → Copier le code.' }
  $fuel = 'gazole'
  if ($data._fuel -and $Fuels.Contains([string]$data._fuel)) { $fuel = [string]$data._fuel }
  $ids = @()
  foreach ($p in $data.PSObject.Properties) {
    if ($p.Name -notlike '_*' -and $p.Value -is [array]) { $ids += @($p.Value | ForEach-Object { [long]$_ }) }
  }
  [pscustomobject]@{ Fuel = $fuel; Ids = @($ids | Sort-Object -Unique) }
}

# --- Noms et marques des stations (names.js de l'application) ---
function Read-Names {
  $path = Join-Path $Root 'names.js'
  if (-not (Test-Path $path)) { return $null }
  $txt = [IO.File]::ReadAllText($path)
  if ($txt -notmatch 'window\.STATION_NAMES\s*=\s*(\{.*\});') { return $null }
  $Matches[1] | ConvertFrom-Json
}

function Get-Stations($ids, $fuel) {
  $rows = @()
  for ($i = 0; $i -lt $ids.Count; $i += 50) {
    $part = $ids[$i..([Math]::Min($i + 49, $ids.Count - 1))]
    $where = ($part | ForEach-Object { "id=$_" }) -join ' or '
    $select = "id,adresse,ville,cp,geom,${fuel}_prix,${fuel}_maj,${fuel}_rupture_type,${fuel}_rupture_debut"
    $url = $Api + '?where=' + [uri]::EscapeDataString($where) + '&select=' + [uri]::EscapeDataString($select) + '&limit=100'
    $rows += @((Invoke-RestMethod -Uri $url -TimeoutSec 60).results)
  }
  $rows
}

# État d'un carburant dans une station : rupture (temporaire), dispo, ou autre (arrêté, non vendu)
function Get-Status($row, $fuel) {
  $rt = $row."${fuel}_rupture_type"; $price = $row."${fuel}_prix"
  if ($rt -eq 'temporaire') { return 'rupture' }
  if (-not $rt -and $null -ne $price) { return 'dispo' }
  'autre'
}

function Get-Title($row, $names) {
  $n = if ($names) { $names.([string]$row.id) } else { $null }
  $ville = (Get-Culture).TextInfo.ToTitleCase(([string]$row.ville).ToLower())
  if ($n -and $n.n) { return ((Get-Culture).TextInfo.ToTitleCase(([string]$n.n).ToLower()) + $(if ($n.b) { " ($($n.b))" } else { '' })) }
  "Station $ville"
}

function Send-Alert($subject, $body) {
  $user = $env:SMTP_USER; $pass = $env:SMTP_PASSWORD
  $to = if ($env:MAIL_TO) { $env:MAIL_TO } else { $user }
  if (-not $user -or -not $pass) {
    if ($env:GITHUB_ACTIONS) { Write-Host "::warning title=Alertes::E-mail non envoyé : les secrets SMTP_USER et SMTP_PASSWORD sont vides ou introuvables (Settings → Secrets and variables → Actions, onglet Secrets)." }
    Write-Host "--- Essai à blanc (pas d'identifiants SMTP) : e-mail non envoyé ---"
    Write-Host "Objet : $subject"; Write-Host $body; return
  }
  $smtpHost = if ($env:SMTP_HOST) { $env:SMTP_HOST } else { 'smtp.gmail.com' }
  $port = if ($env:SMTP_PORT) { [int]$env:SMTP_PORT } else { 587 }
  $msg = New-Object System.Net.Mail.MailMessage
  $msg.From = New-Object System.Net.Mail.MailAddress($user, 'Ma station service Éco')
  foreach ($a in ($to -split '[,;]')) { if ($a.Trim()) { $msg.To.Add($a.Trim()) } }
  $msg.Subject = $subject; $msg.Body = $body
  $msg.SubjectEncoding = $msg.BodyEncoding = [Text.Encoding]::UTF8
  $smtp = New-Object System.Net.Mail.SmtpClient($smtpHost, $port)
  $smtp.EnableSsl = $true
  $smtp.Credentials = New-Object System.Net.NetworkCredential($user, $pass)
  $smtp.Send($msg); $msg.Dispose(); $smtp.Dispose()
  Write-Host "E-mail envoyé : $subject"
  if ($env:GITHUB_ACTIONS) { Write-Host "::notice title=Alertes::E-mail envoyé à $to : $subject" }
}

# --- Programme principal ---
$fav = Read-Favoris
$label = $Fuels[$fav.Fuel]
if (-not $fav.Ids.Count) {
  Write-Host "::warning title=Alertes::Aucune station favorite dans favoris.js : rien à surveiller. Collez-y votre code (Paramètres → Copier le code)."
  if ($env:TEST_MAIL -eq 'true') {
    Send-Alert "Test – alertes Ma station service Éco ($label)" ("L'envoi d'e-mails fonctionne, mais aucune station favorite n'est surveillée : favoris.js n'en contient pas.`n`nDans l'application : Paramètres → Sauvegarde des favorites → Copier le code, puis collez ce code dans favoris.js sur GitHub.")
  }
  return
}
Write-Host "Surveillance de $($fav.Ids.Count) station(s) favorite(s), carburant : $label"

$names = Read-Names
$rows = Get-Stations $fav.Ids $fav.Fuel
$state = if (Test-Path $StateFile) { [IO.File]::ReadAllText($StateFile) | ConvertFrom-Json } else { $null }
$prev = if ($state -and $state.($fav.Fuel)) { $state.($fav.Fuel) } else { $null }

$now = [ordered]@{}; $back = @()
foreach ($r in $rows) {
  $sid = [string]$r.id; $st = Get-Status $r $fav.Fuel
  $now[$sid] = $st
  $before = if ($prev) { $prev.$sid } else { $null }
  Write-Host ("  {0,-10} {1,-8} (avant : {2}) {3}" -f $sid, $st, $(if ($before) { $before } else { '—' }), (Get-Title $r $names))
  if ($before -eq 'rupture' -and $st -eq 'dispo') { $back += $r }
}

$app = if ($env:APP_URL) { "`n`nOuvrir l'application : $($env:APP_URL)" } else { '' }
function Format-Station($r) {
  $price = $r."$($fav.Fuel)_prix"; $maj = [string]$r."$($fav.Fuel)_maj"
  if ($maj.Length -ge 16) { $maj = $maj.Substring(8, 2) + '/' + $maj.Substring(5, 2) + ' à ' + $maj.Substring(11, 5) }
  $dest = [uri]::EscapeDataString("$(Get-Title $r $names), $($r.adresse), $($r.cp) $($r.ville)")
  "• $(Get-Title $r $names)`n  $($r.adresse), $($r.cp) $($r.ville)`n  $label : $(('{0:N3}' -f [double]$price).Replace('.', ',')) € (mis à jour le $maj)`n  Itinéraire : https://www.google.com/maps/dir/?api=1&travelmode=driving&destination=$dest"
}

if ($back.Count) {
  $subject = if ($back.Count -eq 1) { "⛽ $label de nouveau disponible : $(Get-Title $back[0] $names)" } else { "⛽ $label de nouveau disponible dans $($back.Count) stations favorites" }
  $body = "Bonne nouvelle : la rupture de $label est terminée.`n`n" + (($back | ForEach-Object { Format-Station $_ }) -join "`n`n") + $app
  Send-Alert $subject $body
} else { Write-Host 'Aucune fin de rupture depuis la dernière vérification.' }

if ($env:TEST_MAIL -eq 'true') {
  $lines = $rows | ForEach-Object { "• $(Get-Title $_ $names) : $(@{ rupture = 'en rupture'; dispo = 'disponible'; autre = 'non vendu' }[(Get-Status $_ $fav.Fuel)])" }
  $news = if ($back.Count) { "Fin de rupture détectée : un e-mail d'alerte vient d'être envoyé pour $($back.Count) station(s)." }
          else { "Rien à signaler : aucune station favorite n'est sortie d'une rupture de $label depuis la dernière vérification." }
  $nRupt = @($rows | Where-Object { (Get-Status $_ $fav.Fuel) -eq 'rupture' }).Count
  $watch = if ($nRupt) { "$nRupt station(s) actuellement en rupture : vous serez prévenu dès que $label y sera de nouveau disponible." }
           else { "Aucune station favorite n'est actuellement en rupture de $label." }
  Send-Alert "Test – alertes Ma station service Éco ($label)" ("Les alertes fonctionnent.`n`n$news`n$watch`n`nStations favorites suivies pour $label :`n" + ($lines -join "`n") + $app)
}

# Enregistre l'état (fichier modifié seulement si quelque chose a changé)
$all = [ordered]@{}
if ($state) { foreach ($p in $state.PSObject.Properties) { $all[$p.Name] = $p.Value } }
$all[$fav.Fuel] = $now
$json = $all | ConvertTo-Json -Depth 5
$old = if (Test-Path $StateFile) { [IO.File]::ReadAllText($StateFile).Trim() } else { '' }
if ($json.Trim() -ne $old) { [IO.File]::WriteAllText($StateFile, $json + "`n", (New-Object Text.UTF8Encoding $false)); Write-Host 'État enregistré.' }
