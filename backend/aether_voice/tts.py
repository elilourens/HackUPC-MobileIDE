import os
from datetime import datetime
from pathlib import Path
from typing import Optional

import requests
from dotenv import load_dotenv

from aether_voice.voices import get_default_voice


def synthesize_speech(
    text: str, prefix: str = "ghost_reply", voice_id_override: Optional[str] = None
) -> tuple[Optional[str], Optional[str]]:
    load_dotenv()
    api_key = os.getenv("ELEVENLABS_API_KEY")
    voice_id = voice_id_override or get_default_voice()

    if not api_key:
        return None, "Missing ELEVENLABS_API_KEY"

    safe_text = (text or "").strip()
    if not safe_text:
        return None, "No text provided"
    safe_text = safe_text[:1000]

    generated_dir = Path(__file__).resolve().parent / "generated"
    generated_dir.mkdir(parents=True, exist_ok=True)

    url = f"https://api.elevenlabs.io/v1/text-to-speech/{voice_id}"
    headers = {
        "xi-api-key": api_key,
        "Content-Type": "application/json",
        "Accept": "audio/mpeg",
    }
    payload = {
        "text": safe_text,
        "model_id": "eleven_flash_v2_5",
        "voice_settings": {"stability": 0.45, "similarity_boost": 0.75},
    }

    try:
        response = requests.post(url, headers=headers, json=payload, timeout=30)
        if response.status_code != 200:
            return None, f"ElevenLabs request failed ({response.status_code})"
    except requests.RequestException as exc:
        return None, f"ElevenLabs connection error: {exc.__class__.__name__}"

    timestamp = datetime.utcnow().strftime("%Y%m%d%H%M%S%f")
    filename = f"{prefix}_{timestamp}.mp3"
    file_path = generated_dir / filename
    file_path.write_bytes(response.content)
    return f"/generated/{filename}", None
