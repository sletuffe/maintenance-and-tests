#!/usr/bin/env bash
#
# Adaptive tile cache purge script for mod_tile based on access time (atime)
# Supprime les tuiles les moins récemment accédées en premier (tri par atime),
# par lots, jusqu'à atteindre TARGET_FREE_KB d'espace libre.

set -euo pipefail

# --- LOCK ---
LOCK_FILE="/tmp/purge-rarely-accessed-tiles.lock"

acquire_lock() {
    exec 9>"${LOCK_FILE}"
    if ! flock -n 9; then
        local pid
        pid=$(cat "${LOCK_FILE}" 2>/dev/null || echo "inconnu")
        echo "⚠️  ATTENTION : le script est déjà en cours d'exécution (PID ${pid}). Abandon." >&2
        exit 1
    fi
    echo $$ >&9
}

release_lock() {
    flock -u 9
    rm -f "${LOCK_FILE}"
}

trap release_lock EXIT
acquire_lock
# ------------

# --- CONFIGURATION ---
# Chemin du cache de tuiles (supporte les wildcards)
TARGET_DIR="/home/big-data/mod_tile/open*map"
# Niveaux de zoom à nettoyer
ZOOMS="{14..18}"

# Seuil de déclenchement en mode normal (charge faible), en KB
# ~95 GB = 100000000 KB
MIN_FREE_KB=100000000

# Seuil de déclenchement en mode urgence (charge élevée), en KB
# ~50 GB = 52428800 KB
EMERGENCY_FREE_KB=52428800

# Cible d'espace libre à atteindre après purge, en KB
# ~200 GB = 209715200 KB
TARGET_FREE_KB=209715200

# Seuil de charge système (load average 1 min) pour basculer en mode urgence
MAX_LOAD=2

# Garde-fou : ne jamais supprimer des tuiles accédées dans les X derniers jours
MIN_AGE=5

# Nombre de fichiers supprimés entre chaque vérification de l'espace disque
BATCH_SIZE=2000
# ---------------------

get_free_space() {
    df -k "$(eval echo ${TARGET_DIR} | awk '{print $1}')" | tail -n 1 | awk '{print $4}'
}

# Déterminer le seuil actif selon la charge système
CURRENT_LOAD=$(awk '{print $1}' /proc/loadavg)
IS_LOW_LOAD=$(awk "BEGIN {print (${CURRENT_LOAD} < ${MAX_LOAD}) ? 1 : 0}")

echo "=== Tile Cache Purge Started: $(date) ==="

FREE_SPACE=$(get_free_space)
echo "Current free space: $((FREE_SPACE / 1024 / 1024)) GB (${FREE_SPACE} KB)"
echo "System load (1min): ${CURRENT_LOAD} (threshold: ${MAX_LOAD})"

if [ "${IS_LOW_LOAD}" = "1" ]; then
    ACTIVE_THRESHOLD=${MIN_FREE_KB}
    echo "Mode: normal (low load) — purge threshold: $((ACTIVE_THRESHOLD / 1024 / 1024)) GB"
else
    ACTIVE_THRESHOLD=${EMERGENCY_FREE_KB}
    echo "Mode: emergency-only (high load) — purge threshold: $((ACTIVE_THRESHOLD / 1024 / 1024)) GB"
fi

# Sortie rapide si l'espace est suffisant
if [ "${FREE_SPACE}" -ge "${ACTIVE_THRESHOLD}" ]; then
    echo "Sufficient free space available. Nothing to do."
    exit 0
fi

echo "Low disk space. Starting purge (target: $((TARGET_FREE_KB / 1024 / 1024)) GB free, safety floor: ${MIN_AGE} days)..."

count=0
target_reached=false

while IFS= read -r -d '' entry; do
    rm -f "${entry#* }"
    count=$((count + 1))

    if [ $((count % BATCH_SIZE)) -eq 0 ]; then
        FREE_SPACE=$(get_free_space)
        echo "  [${count} files deleted] Free space: $((FREE_SPACE / 1024 / 1024)) GB"
        if [ "${FREE_SPACE}" -ge "${TARGET_FREE_KB}" ]; then
            target_reached=true
            break
        fi
    fi
done < <(eval "ionice -c 3 find ${TARGET_DIR}/${ZOOMS} -type f -atime +${MIN_AGE} -printf '%A@ %p\0'" | sort -zn)

# Vérification finale (dernier lot incomplet < BATCH_SIZE)
FREE_SPACE=$(get_free_space)

if $target_reached || [ "${FREE_SPACE}" -ge "${TARGET_FREE_KB}" ]; then
    echo "Success: ${count} files deleted. Free space: $((FREE_SPACE / 1024 / 1024)) GB"
elif [ "${FREE_SPACE}" -ge "${ACTIVE_THRESHOLD}" ]; then
    echo "Partial: ${count} files deleted. Free space: $((FREE_SPACE / 1024 / 1024)) GB (above trigger threshold, below target)"
else
    echo "WARNING: ${count} files deleted but free space ($((FREE_SPACE / 1024 / 1024)) GB) still below trigger threshold. No tiles older than ${MIN_AGE} days remain."
fi

echo "=== Tile Cache Purge Finished: $(date) ==="
