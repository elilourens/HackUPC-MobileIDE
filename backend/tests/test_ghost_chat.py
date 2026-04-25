import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import requests


BASE_URL = "http://127.0.0.1:8000"


def run_test(name: str, payload: dict) -> None:
    print(f"\n=== {name} ===")
    response = requests.post(f"{BASE_URL}/ghost/chat", json=payload, timeout=20)
    print(f"status: {response.status_code}")
    if response.status_code != 200:
        print(response.text)
        return

    data = response.json()
    print(f"language: {data.get('detected_language')}")
    print(f"reply: {data.get('reply')}")
    print(f"summary: {data.get('summary')}")
    print(f"actions: {data.get('suggested_actions')}")
    print(f"audio_path: {data.get('audio_path')}")
    print(f"tts_error: {data.get('tts_error')}")


if __name__ == "__main__":
    run_test(
        "TEST 1 JavaScript Bug",
        {
            "code": "function add(a,b){ return a-b }",
            "question": "What is wrong here?",
            "voice_enabled": True,
        },
    )

    run_test(
        "TEST 2 SwiftUI",
        {
            "code": 'import SwiftUI\nstruct ContentView: View { var body: some View { Text("Hello") } }',
            "question": "What language is this and what does it do?",
            "voice_enabled": False,
        },
    )

    run_test(
        "TEST 3 Python Secret",
        {
            "code": "api_key='12345'\ndef hello():\n    pass",
            "question": "Review this file",
            "voice_enabled": False,
        },
    )
