import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import requests


URL = "http://127.0.0.1:8000/ghost/conversation"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Test Ghost Conversation Mode endpoint.")
    parser.add_argument("--voice", action="store_true", help="Enable TTS for the reply.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    previous_code = "function add(a,b){ return a-b }"
    current_code = "function add(a,b){ return a+b }"
    transcript = "Did that fix it?"

    multipart_fields = [
        ("current_code", (None, current_code)),
        ("previous_code", (None, previous_code)),
        ("transcript", (None, transcript)),
        ("conversation_history", (None, "[]")),
        ("voice_enabled", (None, str(args.voice).lower())),
    ]

    try:
        response = requests.post(URL, files=multipart_fields, timeout=30)
    except requests.RequestException as exc:
        print(f"Request failed: {exc}")
        print("Is backend running on http://127.0.0.1:8000 ?")
        return 1

    print(f"status: {response.status_code}")
    if response.status_code != 200:
        print(response.text)
        return 1

    try:
        data = response.json()
    except ValueError:
        print("Invalid JSON response:")
        print(response.text)
        return 1

    print(f"transcript: {data.get('transcript')}")
    print(f"language: {data.get('detected_language')}")
    print(f"change_summary: {data.get('change_summary')}")
    print(f"diff_preview:\n{data.get('diff_preview')}")
    print(f"reply: {data.get('reply')}")
    print(f"suggested_actions: {data.get('suggested_actions')}")
    print(f"tts_enabled: {data.get('tts_enabled')}")
    print(f"audio_path: {data.get('audio_path')}")
    print(f"tts_error: {data.get('tts_error')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
