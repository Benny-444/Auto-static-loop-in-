#!/usr/bin/env bash
# auto_loop_in.sh - v6 (fee-checked, yes-piped execution)
set -uo pipefail

LAST_HOP="021c97a90a411ff2b10dc2a8e32de2f29d2fa49d41bfbb52bd416e460db0747d0d"
LOG_FILE="$HOME/looper/loop_in.log"
MAX_FEE_SATS=100

LOOP_ARGS=(
  sudo -n /usr/local/bin/loop
  --rpcserver=localhost:8443
  --macaroonpath=/home/lit/.loop/mainnet/loop.macaroon
  --tlscertpath=/home/lit/.lit/tls.cert
)

echo "=== Auto Loop-In v6 ==="

# 1. Ready deposits — DEPOSITED state only
JSON=$("${LOOP_ARGS[@]}" static listdeposits 2>/dev/null || echo '{"filtered_deposits":[]}')
READY=$(echo "$JSON" | jq -r '
  .filtered_deposits[]
  | select(.state == "DEPOSITED")
  | [(.value | tonumber), .outpoint]
  | @tsv
')

if [[ -z "$READY" ]]; then
    echo "No deposits in DEPOSITED state found."
    echo "Nothing to do."
    exit 0
fi

# 2. Channel info
CHAN_DATA=$(lncli listchannels --peer "$LAST_HOP" | jq -r '.channels[0]')
REMOTE_BAL=$(echo "$CHAN_DATA" | jq -r '.remote_balance // 0')
RESERVE=$(echo "$CHAN_DATA" | jq -r '.remote_chan_reserve_sat // 0')

if [[ "$REMOTE_BAL" -eq 0 ]]; then
    echo "Error: Could not find active channel for last_hop $LAST_HOP"
    exit 1
fi

USABLE=$(( REMOTE_BAL - RESERVE ))
SAFE_MAX=$(( USABLE * 99 / 100 ))

# 3. Largest that fits
CANDIDATES=$(echo "$READY" | awk -v max="$SAFE_MAX" '$1 <= max {print $0}')

if [[ -z "$CANDIDATES" ]]; then
    LARGEST=$(echo "$READY" | sort -k1,1nr | head -1 | cut -f1)
    echo "Nothing to do — no DEPOSITED UTXO fits"
    echo "Safe inbound limit    : ${SAFE_MAX} sats"
    echo "Largest ready deposit : ${LARGEST} sats"
    exit 0
fi

SELECTED=$(echo "$CANDIDATES" | sort -k1,1nr | head -1)
AMOUNT=$(echo "$SELECTED" | cut -f1)
OUTPOINT=$(echo "$SELECTED" | cut -f2)

echo "Selected UTXO         : ${OUTPOINT}"
echo "Amount                : ${AMOUNT} sats"
echo "Channel remote balance: ${REMOTE_BAL} sats"
echo "Channel reserve       : ${RESERVE} sats"
echo "Usable inbound        : ${USABLE} sats"
echo "Safe inbound limit    : ${SAFE_MAX} sats"

# 4. Dry-run to get fee quote (auto-decline with "n")
echo ""
echo "Fetching fee quote..."
QUOTE_OUTPUT=$(echo "n" | "${LOOP_ARGS[@]}" static in \
    --utxo "$OUTPOINT" \
    --last_hop "$LAST_HOP" 2>&1)

echo "$QUOTE_OUTPUT"

QUOTED_FEE=$(echo "$QUOTE_OUTPUT" | grep "Estimated total fee:" | awk '{print $(NF-1)}')

if [[ -z "$QUOTED_FEE" ]]; then
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    echo "❌ Could not parse fee from quote output. Aborting."
    echo "[${TIMESTAMP}] ABORTED — could not parse fee quote for ${OUTPOINT}" >> "$LOG_FILE"
    exit 1
fi

echo ""
echo "Quoted fee            : ${QUOTED_FEE} sats"
echo "Max allowed fee       : ${MAX_FEE_SATS} sats"

if [[ "$QUOTED_FEE" -gt "$MAX_FEE_SATS" ]]; then
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    echo "❌ Fee too high — aborting."
    echo "[${TIMESTAMP}] ABORTED — fee ${QUOTED_FEE} sats exceeds max ${MAX_FEE_SATS} sats | UTXO: ${OUTPOINT}" >> "$LOG_FILE"
    exit 0
fi

echo "✅ Fee within limit — proceeding with swap."

# 5. Execute loop-in with --force
echo ""
echo "Starting loop-in now..."
LOOP_OUTPUT=$(yes | "${LOOP_ARGS[@]}" static in \
    --utxo "$OUTPOINT" \
    --last_hop "$LAST_HOP" 2>&1)

echo "$LOOP_OUTPUT"

# 6. Confirm success
JSON_PART=$(echo "$LOOP_OUTPUT" | tr -d '\n' | grep -o '{.*"swap_hash".*}' | tail -1)
SWAP_HASH=$(echo "$JSON_PART" | jq -r '.swap_hash // ""')
FEE=$(echo "$JSON_PART" | jq -r '.quoted_swap_fee_satoshis // ""')

if [[ -n "$SWAP_HASH" && -n "$FEE" ]]; then
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${TIMESTAMP}] SUCCESS: Looped-in ${AMOUNT} sats | Fees: ${FEE} sats | UTXO: ${OUTPOINT} | Swap hash: ${SWAP_HASH}" >> "$LOG_FILE"
    echo ""
    echo "✅ SUCCESS!"
    echo "Looped-in : ${AMOUNT} sats"
    echo "Fees      : ${FEE} sats"
    echo "UTXO      : ${OUTPOINT}"
    echo "Swap hash : ${SWAP_HASH}"
    ~/looper/auto_fee_adjust.sh
else
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    echo "❌ Could not confirm success (raw output above)"
    echo "[${TIMESTAMP}] FAILED or unclear: ${OUTPOINT}" >> "$LOG_FILE"
fi

echo ""
echo "=== Loop-In Complete ==="
echo "Full log: ${LOG_FILE}"
