#!/bin/bash

# Konfiguration
[ -f ".env" ] && . ./.env

MIN_PDF_SIZE=5000000
WAIT_TIME=80
MAX_TRIES=3
MAX_ISSUES=27 # c't hat bis zu 27 Ausgaben

# Farben
INFO="[\033[0;36mINFO\033[0m]"
SUCCESS="[\033[0;32mSUCCESS\033[0m]"
SKIP="[\033[0;33mSKIP\033[0m]"
ERR="[\033[0;31mERROR\033[0m]"

usage() {  
    echo "Usage: $0 [-v] <magazine> <start_year> [end_year]"
    echo "Example: $0 ct 2022 2023"
    exit 1  
} 

verbose=false
while getopts v name; do
    case $name in
        v) verbose=true;;
        *) usage;;
    esac
done
shift $((OPTIND -1))

[ -z "$2" ] && usage
MAGAZINE=$1
START_YEAR=$2
END_YEAR=${3:-$START_YEAR}

# Validierung
if [ -z "$HEISE_USERNAME" ] || [ -z "$HEISE_PASSWORD" ]; then
    echo -e "${ERR} HEISE_USERNAME oder HEISE_PASSWORD nicht in .env gefunden!"
    exit 1
fi

SESSION_FILE=$(mktemp /tmp/heise_session.XXXXXX)
count_success=0; count_fail=0; count_skip=0

# Progressbar Funktion
sleepbar() {
    local duration=$1
    local pstr="[=============================================================]"
    for i in $(seq 1 $duration); do
        sleep 1
        local pd=$(( i * ${#pstr} / duration ))
        printf "\rWaiting for retry... %d/%ds - %.${pd}s" "$i" "$duration" "$pstr"
    done
    printf "\r\033[2K"
}

# Login Prozess
echo "Logging in as ${HEISE_USERNAME}..."
CURL_OPTS="-L -k -b ${SESSION_FILE} -c ${SESSION_FILE} --no-progress-meter"
$verbose || CURL_OPTS="${CURL_OPTS} -s"

# 1. Login Seite aufrufen & Tokens abgreifen
LOGIN_HTML=$(curl ${CURL_OPTS} -F "username=${HEISE_USERNAME}" -F "password=${HEISE_PASSWORD}" -F "ajax=1" "https://www.heise.de/sso/login/login")

# Extrahiere Tokens (nutzt grep mit Lookbehind für sauberere Ergebnisse)
TOKENS=$(echo "$LOGIN_HTML" | grep -oP '(?<=token=")[^"]+')
TOKEN1=$(echo "$TOKENS" | sed -n '1p')
TOKEN2=$(echo "$TOKENS" | sed -n '2p')

if [ -z "$TOKEN1" ]; then
    echo -e "${ERR} Login fehlgeschlagen (Token konnte nicht extrahiert werden)."
    exit 1
fi

# 2. SSO Remote Logins
curl ${CURL_OPTS} -F "token=${TOKEN1}" "https://m.heise.de/sso/login/remote-login" >/dev/null
curl ${CURL_OPTS} -F "token=${TOKEN2}" "https://shop.heise.de/customer/account/loginRemote" >/dev/null

# Download Loop
for year in $(seq "$START_YEAR" "$END_YEAR"); do
    $verbose && echo -e "${INFO} Processing Year $year"
    for i in $(seq 1 "$MAX_ISSUES"); do
        ISSUE=$(printf "%02d" "$i")
        BASE_PATH="${MAGAZINE}/${year}/${MAGAZINE}.${year}.${ISSUE}"
        LOG_PFX="[$MAGAZINE][$year/$ISSUE]"

        [ -f "${BASE_PATH}.pdf" ] && { echo -e "${LOG_PFX} ${SKIP} Existiert bereits."; count_skip=$((count_skip+1)); continue; }

        # Thumbnail Test (Check ob Ausgabe existiert)
        mkdir -p "$(dirname "$BASE_PATH")"
        HTTP_CODE=$(curl -o "${BASE_PATH}.jpg" -w "%{http_code}" ${CURL_OPTS} "https://heise.cloudimg.io/v7/_www-heise-de_/select/thumbnail/${MAGAZINE}/${year}/${i}.jpg")

        if [ "$HTTP_CODE" -ne 200 ]; then
            rm -f "${BASE_PATH}.jpg"
            # Nach Ausgabe 13 (oder 27) aufhören, falls nichts mehr kommt
            [ "$i" -gt 13 ] && break || continue
        fi

        # Download PDF
        try=1
        success=false
        while [ $try -le $MAX_TRIES ]; do
            echo -ne "${LOG_PFX} [Try $try/$MAX_TRIES] Downloading...\r"
            
            # Header Check
            CTYPE=$(curl -I ${CURL_OPTS} "https://www.heise.de/select/${MAGAZINE}/archiv/${year}/${i}/download" | grep -i "Content-Type" | cut -d' ' -f2 | tr -d '\r')
            
            if [[ "$CTYPE" == *"octet-stream"* ]] || [[ "$CTYPE" == *"pdf"* ]]; then
                SIZE=$(curl -# ${CURL_OPTS} "https://www.heise.de/select/${MAGAZINE}/archiv/${year}/${i}/download" -o "${BASE_PATH}.pdf" -w "%{size_download}")
                
                if [ "$SIZE" -gt "$MIN_PDF_SIZE" ]; then
                    echo -e "${LOG_PFX} ${SUCCESS} Fertig ($((SIZE/1024/1024)) MB)"
                    success=true
                    count_success=$((count_success+1))
                    break
                else
                    echo -e "\n${LOG_PFX} ${ERR} Datei zu klein."
                fi
            else
                echo -e "\n${LOG_PFX} ${ERR} Kein PDF (Sonderheft/Kein Abo?)."
            fi
            
            [ $try -lt $MAX_TRIES ] && sleepbar $WAIT_TIME
            try=$((try+1))
        done

        $success || { echo -e "${LOG_PFX} ${ERR} Download fehlgeschlagen."; count_fail=$((count_fail+1)); }
    done
done

echo "---------------------------------------------------------------"
echo "Summary: $count_success downloaded, $count_fail failed, $count_skip skipped."
rm -f "$SESSION_FILE"
