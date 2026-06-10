#!/usr/bin/env bash
# Usage: BMC_PASSWORD='...' check_versions.sh <BMC_IP> [ASUS_MODEL]
# Prints current BMC FW / BIOS / power state via Redfish; with ASUS_MODEL also
# queries ASUS's download API for the latest published BIOS + BMC versions.
set -u
IP="${1:?usage: check_versions.sh <BMC_IP> [ASUS_MODEL]}"
MODEL="${2:-}"
USER="${BMC_USERNAME:-admin}"
PASS="${BMC_PASSWORD:?set BMC_PASSWORD env var}"
A="$USER:$PASS"
B="https://$IP/redfish/v1"

j() { python3 -c "$1" 2>/dev/null; }

M=$(curl -ksm 10 -u "$A" "$B/Managers" | j "import sys,json;print(json.load(sys.stdin)['Members'][0]['@odata.id'])")
S=$(curl -ksm 10 -u "$A" "$B/Systems"  | j "import sys,json;print(json.load(sys.stdin)['Members'][0]['@odata.id'])")
[ -z "$M" ] && { echo "ERROR: Redfish unreachable on $IP (BMC down or in flash mode?)"; exit 1; }

echo "== $IP current =="
curl -ksm 10 -u "$A" "https://$IP$M" | j "
import sys,json; d=json.load(sys.stdin)
print('BMC FW :', d.get('FirmwareVersion'))"
curl -ksm 10 -u "$A" "https://$IP$S" | j "
import sys,json; d=json.load(sys.stdin)
print('BIOS   :', d.get('BiosVersion'))
print('Power  :', d.get('PowerState'))"
curl -ksm 10 -u "$A" "$B/UpdateService" | j "
import sys,json; d=json.load(sys.stdin)
c=d.get('Oem',{}).get('BMC',{}).get('DualImageConfigurations',{})
print('Images : 1=%s 2=%s active=%s' % (c.get('FirmwareImage1Version'), c.get('FirmwareImage2Version'), c.get('ActiveImage')))"

if [ -n "$MODEL" ]; then
  echo "== ASUS latest for $MODEL =="
  curl -ksm 20 "https://www.asus.com/support/api/product.asmx/GetPDBIOS?website=global&model=$MODEL&cpu=&osid=" | j "
import sys,json
d=json.load(sys.stdin)
for o in d.get('Result',{}).get('Obj',[]):
    print('--', o.get('Name',''))
    for f in o.get('Files',[])[:4]:
        print('%-10s %-10s %s' % (f.get('Version'), f.get('ReleaseDate'), f.get('DownloadUrl',{}).get('Global','')))"
fi
