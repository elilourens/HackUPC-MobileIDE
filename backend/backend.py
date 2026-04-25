import base64
import json
import math
import os
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

from bson import ObjectId
from dotenv import load_dotenv
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import Response
from fastapi.staticfiles import StaticFiles
from motor.motor_asyncio import AsyncIOMotorClient
from openai import OpenAI
from pydantic import BaseModel

from aether_voice.tts import synthesize_speech
from ghost.assistant import generate_conversation_reply, generate_ghost_reply
from ghost.schemas import (
    ConversationTurn,
    GhostChatRequest,
    GhostChatResponse,
    GhostConversationResponse,
    TtsResponse,
    TtsTestRequest,
)
from speech.transcribe import transcribe_audio

load_dotenv()

app = FastAPI(title="AETHER Ghost Pair Programmer")

GHOST_REPLY_VOICE_ID = "lUTamkMw7gOzZbFIwmq4"

EMBEDDING_MODEL = "text-embedding-3-large"
VISION_MODEL = "gpt-4o"
DB_NAME = "mobileide"
COLLECTION = "images"

openai_client = OpenAI(api_key=os.getenv("OPENAI_API_KEY")) if os.getenv("OPENAI_API_KEY") else None

app.add_middleware(
    CORSMiddleware,
    allow_origins=[
        "http://localhost:3000",
        "http://127.0.0.1:3000",
        "http://localhost:5173",
        "http://127.0.0.1:5173",
        "null",
    ],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

generated_dir = Path(__file__).resolve().parent / "aether_voice" / "generated"
generated_dir.mkdir(parents=True, exist_ok=True)
app.mount("/generated", StaticFiles(directory=str(generated_dir)), name="generated")


@app.on_event("startup")
async def startup():
    mongo_uri = os.getenv("MONGODB_URI")
    if mongo_uri:
        app.state.mongo = AsyncIOMotorClient(mongo_uri)
        app.state.col = app.state.mongo[DB_NAME][COLLECTION]
    else:
        app.state.mongo = None
        app.state.col = None


@app.on_event("shutdown")
async def shutdown():
    if getattr(app.state, "mongo", None):
        app.state.mongo.close()


class EmbedResponse(BaseModel):
    id: str
    vector: list[float]
    description: str
    dimensions: int


class SearchResult(BaseModel):
    id: str
    filename: str
    description: str
    score: float


def _to_bool(value: str | bool | None, default: bool) -> bool:
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    return str(value).strip().lower() in {"1", "true", "yes", "on"}


def _require_openai() -> OpenAI:
    if openai_client is None:
        raise HTTPException(500, "OPENAI_API_KEY is not set")
    return openai_client


def _require_mongo_collection():
    col = getattr(app.state, "col", None)
    if col is None:
        raise HTTPException(500, "MONGODB_URI is not set or MongoDB is unavailable")
    return col


def image_to_data_url(data: bytes, content_type: str) -> str:
    encoded = base64.b64encode(data).decode()
    return f"data:{content_type};base64,{encoded}"


def describe_image(data_url: str) -> str:
    client = _require_openai()
    response = client.chat.completions.create(
        model=VISION_MODEL,
        messages=[
            {
                "role": "user",
                "content": [
                    {
                        "type": "image_url",
                        "image_url": {"url": data_url, "detail": "high"},
                    },
                    {
                        "type": "text",
                        "text": (
                            "Describe this image in rich detail, covering objects, colors, "
                            "scene, mood, style, and any text or notable elements. "
                            "Be thorough — this description will be used to generate a semantic embedding."
                        ),
                    },
                ],
            }
        ],
        max_tokens=500,
    )
    return response.choices[0].message.content or ""


def embed_text(text: str) -> list[float]:
    client = _require_openai()
    response = client.embeddings.create(model=EMBEDDING_MODEL, input=text)
    return response.data[0].embedding


def cosine_similarity(a: list[float], b: list[float]) -> float:
    dot = sum(x * y for x, y in zip(a, b))
    norm_a = math.sqrt(sum(x * x for x in a))
    norm_b = math.sqrt(sum(x * x for x in b))
    return dot / (norm_a * norm_b) if norm_a and norm_b else 0.0


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
            base_response["reply"],
            voice_id_override=GHOST_REPLY_VOICE_ID,
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


@app.post("/ghost/conversation", response_model=GhostConversationResponse)
async def ghost_conversation(
    current_code: str = Form(...),
    previous_code: Optional[str] = Form(None),
    transcript: Optional[str] = Form(None),
    conversation_history: Optional[str] = Form(None),
    voice_enabled: str | bool | None = Form(True),
    audio_file: UploadFile | None = File(None),
) -> GhostConversationResponse:
    final_transcript = (transcript or "").strip()
    transcription_error = None

    if not final_transcript and audio_file is not None:
        suffix = Path(audio_file.filename or "audio.wav").suffix or ".wav"

        with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as temp_file:
            temp_file.write(await audio_file.read())
            temp_path = temp_file.name

        try:
            final_transcript, transcription_error = transcribe_audio(temp_path)
            final_transcript = (final_transcript or "").strip()
        finally:
            if os.path.exists(temp_path):
                os.unlink(temp_path)

    if not final_transcript:
        if transcription_error:
            raise HTTPException(status_code=422, detail=transcription_error)
        raise HTTPException(
            status_code=422,
            detail="Provide either transcript text or audio_file for conversation mode.",
        )

    parsed_history: list[ConversationTurn] = []

    if conversation_history:
        try:
            raw_history = json.loads(conversation_history)
            parsed_history = [ConversationTurn(**item) for item in raw_history]
        except Exception:
            raise HTTPException(
                status_code=422,
                detail="conversation_history must be a valid JSON list",
            )

    conversation_data = generate_conversation_reply(
        transcript=final_transcript,
        current_code=current_code,
        previous_code=previous_code,
        conversation_history=parsed_history,
    )

    tts_enabled = False
    audio_path = None
    tts_error = None

    if _to_bool(voice_enabled, default=True):
        audio_path, tts_error = synthesize_speech(
            conversation_data["reply"],
            voice_id_override=GHOST_REPLY_VOICE_ID,
        )
        tts_enabled = audio_path is not None

    return GhostConversationResponse(
        transcript=conversation_data["transcript"],
        detected_language=conversation_data["detected_language"],
        change_summary=conversation_data["change_summary"],
        diff_preview=conversation_data["diff_preview"],
        reply=conversation_data["reply"],
        suggested_actions=conversation_data["suggested_actions"],
        audio_path=audio_path,
        tts_enabled=tts_enabled,
        tts_error=tts_error,
    )


@app.post("/embed/image", response_model=EmbedResponse)
async def embed_image(file: UploadFile = File(...)):
    col = _require_mongo_collection()

    if not file.content_type or not file.content_type.startswith("image/"):
        raise HTTPException(400, "File must be an image")

    data = await file.read()

    if len(data) > 20 * 1024 * 1024:
        raise HTTPException(400, "Image must be under 20MB")

    data_url = image_to_data_url(data, file.content_type)
    description = describe_image(data_url)
    vector = embed_text(description)

    doc = {
        "filename": file.filename,
        "content_type": file.content_type,
        "image_data": data,
        "description": description,
        "embedding": vector,
        "created_at": datetime.now(timezone.utc),
    }

    result = await col.insert_one(doc)

    return EmbedResponse(
        id=str(result.inserted_id),
        vector=vector,
        description=description,
        dimensions=len(vector),
    )


@app.post("/embed/images/batch", response_model=list[EmbedResponse])
async def embed_images_batch(files: list[UploadFile] = File(...)):
    col = _require_mongo_collection()

    if len(files) > 10:
        raise HTTPException(400, "Max 10 images per batch")

    results: list[EmbedResponse] = []

    for file in files:
        if not file.content_type or not file.content_type.startswith("image/"):
            raise HTTPException(400, f"{file.filename} is not an image")

        data = await file.read()

        if len(data) > 20 * 1024 * 1024:
            raise HTTPException(400, f"{file.filename} must be under 20MB")

        data_url = image_to_data_url(data, file.content_type)
        description = describe_image(data_url)
        vector = embed_text(description)

        doc = {
            "filename": file.filename,
            "content_type": file.content_type,
            "image_data": data,
            "description": description,
            "embedding": vector,
            "created_at": datetime.now(timezone.utc),
        }

        result = await col.insert_one(doc)

        results.append(
            EmbedResponse(
                id=str(result.inserted_id),
                vector=vector,
                description=description,
                dimensions=len(vector),
            )
        )

    return results


@app.post("/search/image", response_model=list[SearchResult])
async def search_by_image(file: UploadFile = File(...), top_k: int = 5):
    col = _require_mongo_collection()

    if not file.content_type or not file.content_type.startswith("image/"):
        raise HTTPException(400, "File must be an image")

    data = await file.read()
    data_url = image_to_data_url(data, file.content_type)
    description = describe_image(data_url)
    query_vector = embed_text(description)

    docs = await col.find(
        {},
        {"_id": 1, "filename": 1, "description": 1, "embedding": 1},
    ).to_list(length=None)

    scored = [
        SearchResult(
            id=str(doc["_id"]),
            filename=doc["filename"],
            description=doc["description"],
            score=cosine_similarity(query_vector, doc["embedding"]),
        )
        for doc in docs
        if "embedding" in doc
    ]

    scored.sort(key=lambda x: x.score, reverse=True)
    return scored[:top_k]


@app.post("/search/text", response_model=list[SearchResult])
async def search_by_text(query: str, top_k: int = 5):
    col = _require_mongo_collection()

    if not query.strip():
        raise HTTPException(400, "Query cannot be empty")

    query_vector = embed_text(query)

    docs = await col.find(
        {},
        {"_id": 1, "filename": 1, "description": 1, "embedding": 1},
    ).to_list(length=None)

    scored = [
        SearchResult(
            id=str(doc["_id"]),
            filename=doc["filename"],
            description=doc["description"],
            score=cosine_similarity(query_vector, doc["embedding"]),
        )
        for doc in docs
        if "embedding" in doc
    ]

    scored.sort(key=lambda x: x.score, reverse=True)
    return scored[:top_k]


@app.get("/images")
async def list_images(sort: str = "newest"):
    col = _require_mongo_collection()

    order = -1 if sort == "newest" else 1

    docs = await col.find(
        {},
        {"image_data": 0, "embedding": 0},
    ).sort("created_at", order).to_list(length=None)

    return [
        {
            "id": str(doc["_id"]),
            "filename": doc["filename"],
            "description": doc["description"],
            "created_at": doc["created_at"],
        }
        for doc in docs
    ]


@app.get("/images/{image_id}")
async def get_image(image_id: str):
    col = _require_mongo_collection()

    try:
        oid = ObjectId(image_id)
    except Exception:
        raise HTTPException(400, "Invalid image id")

    doc = await col.find_one(
        {"_id": oid},
        {"image_data": 1, "content_type": 1},
    )

    if not doc:
        raise HTTPException(404, "Image not found")

    return Response(
        content=bytes(doc["image_data"]),
        media_type=doc["content_type"],
    )


@app.delete("/images/{image_id}")
async def delete_image(image_id: str):
    col = _require_mongo_collection()

    try:
        oid = ObjectId(image_id)
    except Exception:
        raise HTTPException(400, "Invalid image id")

    result = await col.delete_one({"_id": oid})

    if result.deleted_count == 0:
        raise HTTPException(404, "Image not found")

    return {"deleted": image_id}