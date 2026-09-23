#!/usr/bin/env python3
import sys
import json
import urllib.request
import urllib.error

# Usage: python3 scripts/coolify/notify_tg.py "Message text here"
BOT_TOKEN = "8663728382:AAHUYJtD4eZe2Ac1fQ4eiFanV_LO_sOr0fo"
CHAT_ID = "1316077326"

def send_alert(message: str):
    if not message:
        return
    url = f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage"
    payload = json.dumps({
        "chat_id": CHAT_ID,
        "text": message,
        "parse_mode": "HTML",
        "disable_web_page_preview": True
    }).encode("utf-8")

    req = urllib.request.Request(
        url,
        data=payload,
        headers={"Content-Type": "application/json"}
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            pass
    except Exception as e:
        print(f"[TG-ALERT] Failed to send telegram alert: {e}", file=sys.stderr)

if __name__ == "__main__":
    if len(sys.argv) > 1:
        text = " ".join(sys.argv[1:])
        text = text.replace("%0A", "\n")
        send_alert(text)
