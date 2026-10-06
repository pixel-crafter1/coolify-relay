#!/usr/bin/env python3
import os
import sys
import json
import urllib.request
import urllib.error

# Runtime credentials must be provided via environment variables (GitHub Actions secrets)
BOT_TOKEN = os.environ.get("TG_BOT_TOKEN", "").strip()
CHAT_ID = os.environ.get("TG_CHAT_ID", "").strip()

def send_alert(message: str):
    if not message:
        return
    if not BOT_TOKEN or not CHAT_ID:
        print("[TG-ALERT] WARNING: TG_BOT_TOKEN or TG_CHAT_ID is missing from environment. Alert not delivered.", file=sys.stderr)
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
