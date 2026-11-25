# Lance le jeu avec les options de vitesse du fork (toutes desactivees par defaut dans le code).
#
# Mesures sur RX 6900 XT + 7800X3D (2026-11-25, scene de la prison, build diag) :
#   off    : ~3.0 fps (335 ms/image)
#   late   : ~5.1 fps (197 ms/image)
#   fast   : ~6.2 fps (160 ms/image)  <- defaut
#   relay  : ~1.8 fps, et perte du GPU (device removed) apres ~1 min dans le monde : a eviter ici.
# Sur RTX 4070 (mesures du fork) : 420-450 ms/image par defaut, 240-350 ms/image avec relay ou late.
#
#   .\run-fast.ps1              -> profil "fast" (late + copies et recopies sur plusieurs threads)
#   .\run-fast.ps1 -Mode late   -> profil "late wait" + tampons en VRAM
#   .\run-fast.ps1 -Mode relay  -> VICTORY_RELAY=2
#   .\run-fast.ps1 -Mode off    -> reglages par defaut (pour comparer)
#
# Le build release n'injecte pas de touches : appuyer sur Entree dans la fenetre du jeu
# pour passer les ecrans de demarrage (environ 1 min 30 apres le lancement).
param(
    [ValidateSet('fast', 'late', 'relay', 'off')]
    [string]$Mode = 'fast',
    [string]$Game = 'E:\GTADump\game_scarlett_master.exe'
)

$names = 'VICTORY_RELAY', 'VICTORY_LATE_WAIT', 'VICTORY_WIDE_BACK',
         'VICTORY_CARD_BUFFERS_MIN_MB', 'VICTORY_CARD_BUFFERS_MB',
         'VICTORY_WIDE_REFRESH', 'VICTORY_WIDE_MERGE', 'VICTORY_JOIN_COPIES',
         'VICTORY_CARD_REHASH_RUNS', 'VICTORY_INDIRECT_WINDOW'
foreach ($n in $names) { Remove-Item "Env:$n" -ErrorAction SilentlyContinue }

function Set-Late {
    $env:VICTORY_LATE_WAIT = '3'
    $env:VICTORY_WIDE_BACK = '1'
    $env:VICTORY_CARD_BUFFERS_MIN_MB = '1'
    $env:VICTORY_CARD_BUFFERS_MB = '1024'
}

switch ($Mode) {
    'fast' {
        Set-Late
        $env:VICTORY_WIDE_REFRESH = '1'
        $env:VICTORY_WIDE_MERGE = '1'
        $env:VICTORY_JOIN_COPIES = '1'
        $env:VICTORY_CARD_REHASH_RUNS = '1'
        $env:VICTORY_INDIRECT_WINDOW = '1'
    }
    'late' { Set-Late }
    'relay' { $env:VICTORY_RELAY = '2' }
}

$exe = Join-Path $PSScriptRoot 'target\release\victory.exe'
Write-Host "Profil: $Mode"
& $exe run $Game --execute
