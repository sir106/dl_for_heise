#!/usr/bin/env python3
import os
import sys
import time
import argparse
import logging
import re
from pathlib import Path

# Try to import dotenv, but don't fail if not present (can rely on env vars)
try:
    from dotenv import load_dotenv
    # Find .env in current directory or parent directories
    load_dotenv()
except ImportError:
    pass

import requests
import urllib3

# Suppress insecure request warnings (equivalent to curl -k)
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# Konfiguration
MIN_PDF_SIZE = 5000000  # 5MB
WAIT_TIME = 80
MAX_TRIES = 3
MAX_ISSUES = 27
DOWNLOAD_DIR = os.environ.get("DOWNLOAD_DIR", "/downloads")

UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

# Setup logging
class ColoredFormatter(logging.Formatter):
    COLORS = {
        'INFO': '\033[0;36m',
        'SUCCESS': '\033[0;32m',
        'WARNING': '\033[0;33m', # Used for SKIP
        'ERROR': '\033[0;31m',
        'DEBUG': '\033[0;36m',
        'RESET': '\033[0m'
    }

    def format(self, record):
        level_name = record.levelname
        color = self.COLORS.get(level_name, self.COLORS['RESET'])
        
        # Replace levelname with formatted one for specific keywords
        if level_name == 'WARNING':
            display_name = 'SKIP'
        elif level_name == 'DEBUG':
            display_name = 'INFO'
        else:
            display_name = level_name
            
        # Avoid prefixing if the message itself is a custom formatted string (like SUCCESS message)
        if hasattr(record, 'no_prefix') and record.no_prefix:
            record.levelname = ""
            return record.getMessage()
            
        record.levelname = f"[{color}{display_name}{self.COLORS['RESET']}]"
        return super().format(record)

def setup_logger(verbose):
    logger = logging.getLogger('heise_dl')
    logger.setLevel(logging.DEBUG if verbose else logging.INFO)
    
    ch = logging.StreamHandler()
    ch.setLevel(logging.DEBUG if verbose else logging.INFO)
    
    formatter = ColoredFormatter('%(levelname)s %(message)s')
    ch.setFormatter(formatter)
    
    logger.addHandler(ch)
    return logger

def sleepbar(duration, prefix="Waiting for retry..."):
    pstr = "[=============================================================]"
    sys.stdout.write('\n') # Newline before bar to not overwrite previous text without carriage return
    for i in range(1, duration + 1):
        time.sleep(1)
        pd = int(i * len(pstr) / duration)
        sys.stdout.write(f"\r{prefix} {i}/{duration}s - {pstr[:pd]}")
        sys.stdout.flush()
    sys.stdout.write("\r\033[2K")
    sys.stdout.flush()

def send_apprise_notification(title, body, msg_type="info", logger=None):
    apprise_url = os.environ.get("APPRISE_URL")
    if not apprise_url:
        return
        
    payload = {
        "title": title,
        "body": body,
        "type": msg_type,
        "format": "text"
    }
    
    try:
        res = requests.post(apprise_url, json=payload, timeout=10, verify=False)
        res.raise_for_status()
    except Exception as e:
        if logger:
            logger.debug(f"Failed to send Apprise notification: {e}")

def main():
    parser = argparse.ArgumentParser(description="Download Heise+ magazines")
    parser.add_argument('-v', '--verbose', action='store_true', help='Enable verbose output')
    parser.add_argument('magazine', help='Magazine name (e.g., ct)')
    parser.add_argument('start_year', type=int, help='Start year')
    parser.add_argument('end_year', type=int, nargs='?', help='End year (optional, defaults to start_year)')
    
    args = parser.parse_args()
    
    end_year = args.end_year if args.end_year else args.start_year
    
    logger = setup_logger(args.verbose)
    
    heise_username = os.environ.get("HEISE_USERNAME")
    heise_password = os.environ.get("HEISE_PASSWORD")
    
    if not heise_username or not heise_password:
        logger.error("HEISE_USERNAME oder HEISE_PASSWORD nicht in .env (oder Environment) gefunden!")
        sys.exit(1)

    # Use a session to persist cookies
    session = requests.Session()
    session.headers.update({"User-Agent": UA})
    
    logger.info(f"Logging in as {heise_username}...")
    logger.info("Sending login request to heise.de...")
    
    login_data = {
        "username": heise_username,
        "password": heise_password,
        "ajax": "1"
    }
    
    try:
        # POST to login
        login_res = session.post("https://www.heise.de/sso/login/login", data=login_data, verify=False)
        login_res.raise_for_status()
    except Exception as e:
        msg = f"Login request failed: {e}"
        logger.error(msg)
        send_apprise_notification("Heise+ Login Error", msg, "error", logger)
        sys.exit(1)
        
    # Extract tokens exactly like awk logic: looking for "token":"..."
    tokens = re.findall(r'"token":"([^"]+)"', login_res.text)
    
    if not tokens:
        msg = "Login fehlgeschlagen (Token konnte nicht extrahiert werden)."
        logger.error(msg)
        send_apprise_notification("Heise+ Login Error", msg, "error", logger)
        sys.exit(1)
        
    token1 = tokens[0]
    token2 = tokens[1] if len(tokens) > 1 else None
    
    logger.info("Login successful. Extracted tokens, performing SSO remote logins...")
    
    try:
        session.post("https://m.heise.de/sso/login/remote-login", data={"token": token1}, verify=False)
        if token2 and token2 != token1:
            logger.info("Performing secondary SSO shop login...")
            session.post("https://shop.heise.de/customer/account/loginRemote", data={"token": token2}, verify=False)
    except Exception as e:
        msg = f"SSO remote login failed: {e}"
        logger.error(msg)
        send_apprise_notification("Heise+ Login Error", msg, "error", logger)
        sys.exit(1)
        
    print(f"[\033[0;32mSUCCESS\033[0m] Login phase completed.")
    
    count_success = 0
    count_fail = 0
    count_skip = 0
    
    for year in range(args.start_year, end_year + 1):
        if args.verbose:
            logger.debug(f"Processing Year {year}")
            
        for i in range(1, MAX_ISSUES + 1):
            issue_str = f"{i:02d}"
            base_dir = Path(DOWNLOAD_DIR) / args.magazine / str(year)
            base_path = base_dir / f"{args.magazine}.{year}.{issue_str}"
            log_pfx = f"[{args.magazine}][{year}/{issue_str}]"
            
            if base_path.with_suffix('.pdf').exists():
                logger.warning(f"{log_pfx} Existiert bereits.") # mapped to SKIP
                count_skip += 1
                continue
                
            base_dir.mkdir(parents=True, exist_ok=True)
            
            if args.verbose:
                logger.debug(f"{log_pfx} Checking if issue exists via thumbnail request...")
                
            thumb_url = f"https://heise.cloudimg.io/v7/_www-heise-de_/select/thumbnail/{args.magazine}/{year}/{i}.jpg"
            thumb_res = session.get(thumb_url, verify=False)
            
            if thumb_res.status_code != 200:
                if args.verbose:
                    logger.warning(f"{log_pfx} Thumbnail not found (HTTP {thumb_res.status_code}). Issue might not exist.")
                if i > 13:
                    break
                else:
                    continue
                    
            if args.verbose:
                logger.debug(f"{log_pfx} Issue found. Starting download sequence.")
                
            success = False
            for try_num in range(1, MAX_TRIES + 1):
                sys.stdout.write(f"{log_pfx} [Try {try_num}/{MAX_TRIES}] Downloading...\r")
                sys.stdout.flush()
                
                download_url = f"https://www.heise.de/select/{args.magazine}/archiv/{year}/{i}/download"
                if args.verbose:
                    # New line to clear the downloading text when debugging
                    sys.stdout.write("\n")
                    logger.debug(f"{log_pfx} Starting download ({download_url})..")
                
                try:
                    pdf_res = session.get(download_url, verify=False, stream=True)
                    content = pdf_res.content
                    size = len(content)
                    
                    if size > MIN_PDF_SIZE:
                        sys.stdout.write(f"\n{log_pfx} [\033[0;32mSUCCESS\033[0m] Fertig ({size//1024//1024} MB)\n")
                        base_path.with_suffix('.pdf').write_bytes(content)
                        
                        # Log history
                        history_log = Path(DOWNLOAD_DIR) / "download_history.log"
                        with open(history_log, "a") as f:
                            timestamp = time.strftime('%Y-%m-%d %H:%M:%S')
                            f.write(f"{timestamp} - Erfolgreich geladen: {base_path}.pdf - Quelle: {download_url}\n")
                        
                        send_apprise_notification(
                            title=f"Heise+ Download Success: {args.magazine.upper()} {year}/{i:02d}",
                            body=f"Successfully downloaded magazine '{args.magazine.upper()}' issue {i:02d} from {year}.\nFile size: {size//1024//1024} MB\nSaved to: {base_path}.pdf",
                            msg_type="success",
                            logger=logger
                        )
                        
                        success = True
                        count_success += 1
                        
                        if args.verbose:
                            logger.debug(f"{log_pfx} Sleeping 60s to be polite to the server...")
                        time.sleep(60)
                        break
                    else:
                        html_snippet = content[:150].decode('utf-8', errors='ignore').replace('\n', ' ')
                        html_snippet = re.sub(r'\s+', ' ', html_snippet).strip()
                        
                        sys.stdout.write(f"\n{log_pfx} [\033[0;31mERROR\033[0m] Download fehlgeschlagen oder kein PDF (Größe: {size} Bytes).\n")
                        if args.verbose:
                            logger.debug(f"{log_pfx} Server response snippet: {html_snippet}...")
                            
                        error_html = base_path.parent / f"{base_path.name}_error_try{try_num}.html"
                        error_html.write_bytes(content)
                        
                        if args.verbose:
                            logger.debug(f"{log_pfx} Saved HTML response to {error_html}")
                            
                except Exception as e:
                    sys.stdout.write(f"\n{log_pfx} [\033[0;31mERROR\033[0m] Request exception: {e}\n")
                
                if try_num < MAX_TRIES:
                    sleepbar(WAIT_TIME)
                    
            if not success:
                sys.stdout.write(f"{log_pfx} [\033[0;31mERROR\033[0m] Download fehlgeschlagen nach {MAX_TRIES} Versuchen.\n")
                
                send_apprise_notification(
                    title=f"Heise+ Download Error: {args.magazine.upper()} {year}/{i:02d}",
                    body=f"Failed to download magazine '{args.magazine.upper()}' issue {i:02d} from {year} after {MAX_TRIES} attempts.",
                    msg_type="error",
                    logger=logger
                )
                
                count_fail += 1
                
    print("\n---------------------------------------------------------------")
    print(f"Summary: {count_success} ok, {count_fail} failed, {count_skip} skipped.")
    
    logger.info("Done!")

if __name__ == "__main__":
    main()
