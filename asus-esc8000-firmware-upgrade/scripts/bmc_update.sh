#!/usr/bin/env bash
# Usage: BMC_PASSWORD='...' bmc_update.sh <BMC_IP> <bmc_firmware.hpm>
# Host-safe BMC firmware update via Redfish multipart push.
# Sets preserve-config flags, uploads, monitors flash, waits for BMC reboot, verifies.
set -u
IP="${1:?usage: bmc_update.sh <BMC_IP> <fw.hpm>}"
FW="${2:?usage: bmc_update.sh <BMC_IP> <fw.hpm>}"
USER="${BMC_USERNAME:-admin}"
PASS="${BMC_PASSWORD:?set BMC_PASSWORD env var}"
A="$USER:$PASS"
B="https://$IP/redfish/v1"
[ -f "$FW" ] || { echo "no such file: $FW"; exit 1; }

echo "[1/5] preserve-config flags -> all true"
ET=$(curl -ksm 10 -u "$A" -o /dev/null -D - "$B/UpdateService" | awk -F': ' 'tolower($1)=="etag"{gsub(/\r/,"");print $2}')
KEYS='"Authentication","EXTLOG","FRU","IPMI","KVM","NTP","Network","REDFISH","SDR","SEL","SNMP","SSH","Syslog","WEB"'
PRES=$(python3 -c "print('{'+','.join('\"%s\":true'%k.strip('\"') for k in [$KEYS])+'}')")
curl -ksm 15 -u "$A" -X PATCH -H "Content-Type: application/json" ${ET:+-H "If-Match: $ET"} \
  -d "{\"Oem\":{\"AMIUpdateService\":{\"PreserveConfiguration\":$PRES}}}" "$B/UpdateService" -o /dev/null -w 'PATCH %{http_code}\n'

echo "[2/5] uploading $(basename "$FW") ..."
RESP=$(curl -ks -w '\nHTTP:%{http_code}' -u "$A" \
  -F 'UpdateParameters={"Targets":["/redfish/v1/UpdateService/FirmwareInventory/BMCImage1"],"@Redfish.OperationApplyTime":"Immediate"};type=application/json' \
  -F 'OemParameters={"ImageType":"HPM"};type=application/json' \
  -F "UpdateFile=@$FW;type=application/octet-stream" \
  --max-time 900 "$B/UpdateService/upload")
echo "$RESP" | tail -1
echo "$RESP" | grep -q 'HTTP:202' || { echo "UPLOAD REJECTED:"; echo "$RESP" | head -3; exit 1; }

echo "[3/5] flashing (BMC stays up until reboot)..."
DOWN=0
for i in $(seq 1 120); do
  OUT=$(curl -ksm 8 -u "$A" "$B/UpdateService" 2>/dev/null | python3 -c "
import sys,json
try:
    o=json.load(sys.stdin)['Oem']['AMIUpdateService']
    print(o.get('FlashPercentage') or '', o.get('UpdateStatus') or '')
except: pass" 2>/dev/null)
  [ -z "$OUT" ] && { DOWN=$((DOWN+1)); echo "  ($i) bmc unreachable (rebooting?)"; } || { DOWN=0; echo "  ($i) $OUT"; }
  [ $DOWN -ge 3 ] && break
  echo "$OUT" | grep -qi complete && break
  sleep 15
done

echo "[4/5] waiting for BMC to come back..."
for i in $(seq 1 60); do
  V=$(curl -ksm 8 -u "$A" "$B/Managers" 2>/dev/null | python3 -c "
import sys,json;print(json.load(sys.stdin)['Members'][0]['@odata.id'])" 2>/dev/null)
  if [ -n "$V" ]; then
    curl -ksm 8 -u "$A" "https://$IP$V" | python3 -c "
import sys,json;print('[5/5] BMC back, FirmwareVersion:', json.load(sys.stdin).get('FirmwareVersion'))"
    echo "NOTE: host may have powered ON via power-restore policy - check before BIOS work."
    exit 0
  fi
  sleep 20
done
echo "BMC did not return within 20 min - investigate"; exit 1
