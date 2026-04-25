from pathlib import Path

from dotenv import load_dotenv
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles

from aether_voice.tts import synthesize_speech
from ghost.assistant import generate_ghost_reply
from ghost.schemas import GhostChatRequest, GhostChatResponse, TtsResponse, TtsTestRequest

load_dotenv()

app = FastAPI(title="AETHER Ghost Pair Programmer")
GHOST_REPLY_VOICE_ID = "lUTamkMw7gOzZbFIwmq4"

app.add_middleware(
    CORSMiddleware,
    allow_origins=[
        "http://localhost:3000",
        "http://127.0.0.1:3000",
        "http://localhost:5173",
        "http://127.0.0.1:5173",
    ],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

generated_dir = Path(__file__).resolve().parent / "aether_voice" / "generated"
generated_dir.mkdir(parents=True, exist_ok=True)
app.mount("/generated", StaticFiles(directory=str(generated_dir)), name="generated")


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok", "service": "aether-ghost"}


@app.post("/ghost/chat", response_model=GhostChatResponse)
def ghost_chat(payload: GhostChatRequest) -> GhostChatResponse:
    base_response = generate_ghost_reply(payload)
    tts_enabled = False
    audio_path = None
    tts_error = None

    if payload.voice_enabled:
        audio_path, tts_error = synthesize_speech(
            base_response["reply"], voice_id_override=GHOST_REPLY_VOICE_ID
        )
        tts_enabled = audio_path is not None

    return GhostChatResponse(
        detected_language=base_response["detected_language"],
        reply=base_response["reply"],
        summary=base_response["summary"],
        suggested_actions=base_response["suggested_actions"],
        tts_enabled=tts_enabled,
        audio_path=audio_path,
        tts_error=tts_error,
    )


@app.post("/ghost/tts-test", response_model=TtsResponse)
def ghost_tts_test(payload: TtsTestRequest) -> TtsResponse:
    audio_path, tts_error = synthesize_speech(payload.text, prefix="test_voice")
    return TtsResponse(
        tts_enabled=audio_path is not None,
        audio_path=audio_path,
        tts_error=tts_error,
    )
