#!/bin/bash

# Konfiguration
[ -f ".env" ] && . ./.env

MIN_PDF_SIZE=5000000 # minimum file size to check if downloaded file is a valid pdf
WAIT_TIME=80 # wait a few seconds between repetitions on errors to prevent rate limiting
MAX_TRIES=3 # if a download fails (or is not a valid pdf), repeat this often

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
echo -e "${INFO} Sending login request to heise.de..."
LOGIN_HTML=$(curl ${CURL_OPTS} -F "username=${HEISE_USERNAME}" -F "password=${HEISE_PASSWORD}" -F "ajax=1" "https://www.heise.de/sso/login/login")

# Extrahiere Token aus JSON Response (BusyBox / awk kompatibel)
TOKENS=$(echo "$LOGIN_HTML" | awk -F'"token":"' '{for(i=2;i<=NF;i++){split($i,a,"\""); print a[1]}}')
if [ -z "$TOKENS" ]; then
    # Fallback Methode, falls das Format abweicht
    TOKENS=$(echo "$LOGIN_HTML" | sed "s/token/\ntoken/g" | grep ^token | cut -f 3 -d '"')
fi

TOKEN1=$(echo "$TOKENS" | sed -n '1p')
TOKEN2=$(echo "$TOKENS" | sed -n '2p')

if [ -z "$TOKEN1" ]; then
    echo -e "${ERR} Login fehlgeschlagen (Token konnte nicht extrahiert werden)."
    rm -f "$SESSION_FILE"
    exit 1
fi

# 2. SSO Remote Logins
echo -e "${INFO} Login successful. Extracted tokens, performing SSO remote logins..."
curl ${CURL_OPTS} -F "token=${TOKEN1}" "https://m.heise.de/sso/login/remote-login" >/dev/null
if [ -n "$TOKEN2" ] && [ "$TOKEN2" != "$TOKEN1" ]; then
    echo -e "${INFO} Performing secondary SSO shop login..."
    curl ${CURL_OPTS} -F "token=${TOKEN2}" "https://shop.heise.de/customer/account/loginRemote" >/dev/null
fi
echo -e "${SUCCESS} Login phase completed."

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
        $verbose && echo -e "${LOG_PFX} Checking if issue exists via thumbnail request..."
        HTTP_CODE=$(curl -o "${BASE_PATH}.jpg" -w "%{http_code}" ${CURL_OPTS} "https://heise.cloudimg.io/v7/_www-heise-de_/select/thumbnail/${MAGAZINE}/${year}/${i}.jpg")

        if [ "$HTTP_CODE" -ne 200 ]; then
            $verbose && echo -e "${LOG_PFX} ${SKIP} Thumbnail not found (HTTP $HTTP_CODE). Issue might not exist."
            rm -f "${BASE_PATH}.jpg"
            # Nach Ausgabe 13 (oder 27) aufhören, falls nichts mehr kommt
            [ "$i" -gt 13 ] && break || continue
        fi
        $verbose && echo -e "${LOG_PFX} Issue found. Starting download sequence."

        # PDF Download Versuche
        try=1
        success=false
        while [ $try -le $MAX_TRIES ]; do
            printf "${LOG_PFX} [Try $try/$MAX_TRIES] Downloading...\r"
            
            # Direkter Download ohne HEAD-Request (spart Requests und vermeidet Rate-Limits)
            DOWNLOAD_URL="https://www.heise.de/select/${MAGAZINE}/archiv/${year}/${i}/download"
            $verbose && echo -e "\n${LOG_PFX} Starting download..."
            SIZE=$(curl -# -b ${SESSION_FILE} -c ${SESSION_FILE} -L -k "$DOWNLOAD_URL" -o "${BASE_PATH}.pdf" -w "%{size_download}")
            
            # Prüfen, ob die Datei groß genug für ein echtes PDF ist
            if [ "$SIZE" -gt "$MIN_PDF_SIZE" ]; then
                printf "\n${LOG_PFX} ${SUCCESS} Fertig ($((SIZE/1024/1024)) MB)\n"
                
                # In eigenes Logfile schreiben
                echo "$(date '+%Y-%m-%d %H:%M:%S') - Erfolgreich geladen: ${BASE_PATH}.pdf - Quelle: $DOWNLOAD_URL" >> download_history.log
                
                success=true
                count_success=$((count_success+1))
                
                # Kurze Pause nach Erfolg, um Sperren bei schnellen aufeinanderfolgenden Downloads zu verhindern
                $verbose && echo -e "${LOG_PFX} Sleeping 15s to be polite to the server..."
                sleep 15
                break
            else
                # Wenn es zu klein ist, war es wahrscheinlich eine HTML Fehlerseite (Rate Limit / Kein Abo)
                HTML_SNIPPET=$(head -c 150 "${BASE_PATH}.pdf" | tr '\n' ' ' | sed 's/  */ /g' 2>/dev/null)
                printf "\n${LOG_PFX} ${ERR} Download fehlgeschlagen oder kein PDF (Größe: $SIZE Bytes).\n"
                $verbose && echo -e "${LOG_PFX} Server response snippet: $HTML_SNIPPET..."
                rm -f "${BASE_PATH}.pdf"
            fi
            
            if [ $try -lt $MAX_TRIES ]; then
                sleepbar $WAIT_TIME
            fi
            try=$((try+1))
        done

        if [ "$success" = false ]; then
            printf "${LOG_PFX} ${ERR} Download fehlgeschlagen nach $MAX_TRIES Versuchen.\n"
            count_fail=$((count_fail+1))
        fi
    done
done

printf "\n---------------------------------------------------------------\n"
printf "Summary: $count_success ok, $count_fail failed, $count_skip skipped.\n"

# Cleanup
echo -e "${INFO} Cleaning up session files..."
rm -f "$SESSION_FILE"
echo -e "${INFO} Done!"
