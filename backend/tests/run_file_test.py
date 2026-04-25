import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import requests


DEFAULT_QUESTION = (
    "Review this code, detect the programming language, find bugs, and suggest improvements."
)
API_URL = "http://127.0.0.1:8000/ghost/chat"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Send a code file to AETHER Ghost for analysis."
    )
    parser.add_argument("file_path", help="Path to the code file to analyze.")
    parser.add_argument(
        "--voice",
        action="store_true",
        help="Enable voice synthesis for the ghost reply.",
    )
    parser.add_argument(
        "--question",
        default=DEFAULT_QUESTION,
        help="Custom question to ask the ghost assistant.",
    )
    return parser.parse_args()


def read_code_file(file_path: str) -> str:
    path = Path(file_path)
    if not path.exists():
        raise FileNotFoundError(f"File does not exist: {path}")
    if not path.is_file():
        raise FileNotFoundError(f"Not a file: {path}")
    return path.read_text(encoding="utf-8")


def print_response(data: dict) -> None:
    print("\n=== AETHER Ghost Response ===")
    print(f"Detected language: {data.get('detected_language', 'unknown')}")
    print(f"Summary: {data.get('summary', '')}")
    print(f"Reply: {data.get('reply', '')}")

    actions = data.get("suggested_actions") or []
    print("Suggested actions:")
    if actions:
        for idx, action in enumerate(actions, start=1):
            print(f"  {idx}. {action}")
    else:
        print("  (none)")

    if data.get("audio_path"):
        print(f"Audio path: {data['audio_path']}")
    if data.get("tts_error"):
        print(f"TTS error: {data['tts_error']}")


def main() -> int:
    args = parse_args()

    try:
        code = read_code_file(args.file_path)
    except FileNotFoundError as exc:
        print(f"Error: {exc}")
        return 1
    except UnicodeDecodeError:
        print("Error: Could not decode file as UTF-8 text.")
        return 1
    except OSError as exc:
        print(f"Error reading file: {exc}")
        return 1

    payload = {
        "code": code,
        "question": args.question,
        "conversation_history": [],
        "voice_enabled": args.voice,
    }

    try:
        response = requests.post(API_URL, json=payload, timeout=30)
    except requests.RequestException:
        print("Error: Could not reach backend at http://127.0.0.1:8000. Is it running?")
        return 1

    if response.status_code != 200:
        print(f"API error: status {response.status_code}")
        print(response.text)
        return 1

    try:
        data = response.json()
    except ValueError:
        print("Error: Backend response is not valid JSON.")
        print(response.text)
        return 1

    if not isinstance(data, dict):
        print("Error: Backend JSON response has unexpected format.")
        return 1

    print_response(data)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
