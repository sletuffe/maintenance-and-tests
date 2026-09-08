#!/usr/bin/env bash
#
# Adaptive tile cache purge script for mod_tile based on access time (atime)

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
# Path to the tile cache (supports wildcards like open*map)
TARGET_DIR="/home/big-data/mod_tile/open*map"
# Target zoom levels to clean up
ZOOMS="{14..18}"

# Minimum free space required in Kilobytes (40 GB = 41943040 KB)
# Formula: GB * 1024 * 1024
MIN_FREE_KB=100000000

# Purge loop parameters
START_AGE=50      # Initial threshold in days to start looking for old tiles
MIN_AGE=5         # Safety floor: never delete tiles accessed within the last X days
AGE_STEP=5        # Decrement value for the day threshold if space is still insufficient
# ---------------------

# Function to retrieve available disk space in KB
get_free_space() {
    # Using 'eval' to properly expand the path and wildcards.
    # 'df -k' outputs space in 1KB blocks; awk extracts the 4th column (Available).
    df -k "$(eval echo ${TARGET_DIR} | awk '{print $1}')" | tail -n 1 | awk '{print $4}'
}

echo "=== Tile Cache Purge Started: $(date) ==="

FREE_SPACE=$(get_free_space)
echo "Current free space: $((FREE_SPACE / 1024 / 1024)) GB (${FREE_SPACE} KB)"

# Quick check: exit immediately if we already have enough space
if [ "${FREE_SPACE}" -ge "${MIN_FREE_KB}" ]; then
    echo "Sufficient free space available (above $((MIN_FREE_KB / 1024 / 1024)) GB). Nothing to do."
    exit 0
fi

CURRENT_AGE=${START_AGE}

# Progressive cleanup loop
while [ "${FREE_SPACE}" -lt "${MIN_FREE_KB}" ] && [ "${CURRENT_AGE}" -ge "${MIN_AGE}" ]; do
    echo "Low disk space. Running purge for tiles older than ${CURRENT_AGE} days..."
    
    # 'eval' is required here to correctly expand bash braces {12..18} and wildcards
    eval "ionice -c 3 find ${TARGET_DIR}/${ZOOMS} -type f -atime +${CURRENT_AGE} -delete" || true
    
    # Brief pause to let the filesystem settle and catch up
    sleep 2
    
    # Recalculate free space
    FREE_SPACE=$(get_free_space)
    echo "Free space after >${CURRENT_AGE}d purge: $((FREE_SPACE / 1024 / 1024)) GB"
    
    # Lower the age threshold for the next iteration if needed
    CURRENT_AGE=$((CURRENT_AGE - AGE_STEP))
done

# Final status check
if [ "${FREE_SPACE}" -lt "${MIN_FREE_KB}" ]; then
    echo "WARNING: Reached the safety floor of ${MIN_AGE} days, but free space ($((FREE_SPACE / 1024 / 1024)) GB) is still below the target threshold."
else
    echo "Success: Free space target achieved."
fi

echo "=== Tile Cache Purge Finished: $(date) ==="
