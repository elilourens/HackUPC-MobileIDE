import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from aether_voice.tts import synthesize_speech


if __name__ == "__main__":
    text = "Aether online. I found a possible bug in your code."
    audio_path, error = synthesize_speech(text, prefix="test_voice")
    if error:
        print(f"TTS failed: {error}")
    else:
        print(f"TTS ok. Saved audio at: {audio_path}")
