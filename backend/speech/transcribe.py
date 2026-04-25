import os
from typing import Optional

from dotenv import load_dotenv


def transcribe_audio(audio_file_path: str) -> tuple[Optional[str], Optional[str]]:
    load_dotenv()

    # Placeholder capability gate for future integrations (Whisper/Deepgram/etc.).
    if not os.getenv("TRANSCRIPTION_API_KEY"):
        return None, "Transcription unavailable: missing TRANSCRIPTION_API_KEY"

    if not os.path.exists(audio_file_path):
        return None, "Transcription failed: audio file not found"

    return None, "Transcription unavailable: no provider integration configured yet"
