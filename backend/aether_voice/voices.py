import os


def get_default_voice() -> str:
    return os.getenv("ELEVENLABS_VOICE_ID", "lUTamkMw7gOzZbFIwmq4")
