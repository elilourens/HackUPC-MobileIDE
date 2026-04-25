from __future__ import annotations

import base64
import json
import math
import os
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional, Union

from bson import ObjectId
from dotenv import load_dotenv
from fastapi import FastAPI, File, Form, HTTPException, UploadFile, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import Response
from fastapi.staticfiles import StaticFiles
from motor.motor_asyncio import AsyncIOMotorClient
from openai import OpenAI
from pydantic import BaseModel, ConfigDict, Field

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
BUILD_MODEL = "gpt-5.4"
DB_NAME = "mobileide"
COLLECTION = "images"
CODE_EDITS_COLLECTION = "code_edits"

BUILD_SYSTEM_PROMPT = """You are a world-class frontend developer at Vercel. Generate a single HTML file.

MANDATORY in <head>:
<script src=\"https://unpkg.com/react@18/umd/react.production.min.js\"></script>
<script src=\"https://unpkg.com/react-dom@18/umd/react-dom.production.min.js\"></script>
<script src=\"https://unpkg.com/@babel/standalone/babel.min.js\"></script>
<script src=\"https://cdn.tailwindcss.com\"></script>
<link href=\"https://fonts.googleapis.com/css2?family=DM+Sans:wght@400;500;700&display=swap\" rel=\"stylesheet\">

<script> tailwind.config = { theme: { extend: { fontFamily: { sans: ['DM Sans', 'sans-serif'] }}}} </script>

Write React components inside <script type=\"text/babel\">.
Use Tailwind classes for ALL styling. No inline styles.
Render into <div id=\"root\">.

DESIGN RULES:
- Dark theme: bg-neutral-950 body, bg-neutral-900 cards
- Accent: ONE color only. blue-500 or emerald-500 or orange-500. Pick one per project.
- Text: text-neutral-50 headings, text-neutral-400 body
- Cards: rounded-2xl border border-neutral-800 p-8
- Spacing: generous. py-24 sections, gap-8 grids
- Typography: text-5xl font-bold tracking-tight headings
- Max width: max-w-6xl mx-auto px-6
- Hover states on buttons and links
- Use real images from unsplash where appropriate:
  https://images.unsplash.com/photo-{ID}?w=800&h=600&fit=crop
- Make it look like linear.app or vercel.com quality
- NO gradients. NO neon. NO borders thicker than 1px.
- NO generic placeholder text. Write real compelling copy.

Return ONLY raw HTML. No markdown. No backticks. No explanation. No comments."""

openai_client = OpenAI(api_key=os.getenv("OPENAI_API_KEY")) if os.getenv("OPENAI_API_KEY") else None

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
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
        app.state.code_edits_col = app.state.mongo[DB_NAME][CODE_EDITS_COLLECTION]
    else:
        app.state.mongo = None
        app.state.col = None
        app.state.code_edits_col = None


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


class BuildRequest(BaseModel):
    prompt: str


class ModifyRequest(BaseModel):
    prompt: str
    current_code: str


class ElementContext(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    tag: Optional[str] = None
    class_: Optional[str] = Field(default=None, alias="class")
    text: Optional[str] = None


class ModifyElementRequest(BaseModel):
    prompt: str
    current_code: str
    element: ElementContext


class BuildResponse(BaseModel):
    html: str
    success: bool


class PlanRequest(BaseModel):
    prompt: str
    current_code: Optional[str] = None


class PlanStep(BaseModel):
    index: int
    action: str          # short verb phrase, e.g. "Create hero section"
    target: str          # path or component, e.g. "index.html · <header>"
    why: str             # one sentence reasoning


class PlanResponse(BaseModel):
    summary: str             # 1-2 sentences for JARVIS to speak
    steps: list[PlanStep]    # ordered execution plan
    expanded_prompt: str     # detailed brief that /api/build will receive once confirmed
    success: bool


def _to_bool(value: Optional[Union[str, bool]], default: bool) -> bool:
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


def _require_code_edits_collection():
    col = getattr(app.state, "code_edits_col", None)
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


connected_clients: dict[str, Optional[WebSocket]] = {"ios": None, "plugin": None}
latest_code: dict[str, str] = {}


@app.websocket("/ws/sync")
async def websocket_sync(websocket: WebSocket):
    await websocket.accept()
    client_type = None
    try:
        data = await websocket.receive_json()
        client_type = data.get("type")
        if client_type not in connected_clients:
            await websocket.close()
            return
        connected_clients[client_type] = websocket

        while True:
            msg = await websocket.receive_json()
            filename = msg.get("filename", "")
            if filename:
                latest_code[filename] = msg.get("code", "")
            other = "plugin" if client_type == "ios" else "ios"
            other_ws = connected_clients.get(other)
            if other_ws:
                try:
                    await other_ws.send_json(msg)
                except Exception:
                    connected_clients[other] = None
    except (WebSocketDisconnect, Exception):
        if client_type:
            connected_clients[client_type] = None


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
    voice_enabled: Optional[Union[str, bool]] = Form(True),
    audio_file: Optional[UploadFile] = File(None),
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


def _strip_html_fence(text: str) -> str:
    stripped = text.strip()
    if stripped.startswith("```"):
        first_newline = stripped.find("\n")
        if first_newline != -1:
            stripped = stripped[first_newline + 1 :]
        if stripped.endswith("```"):
            stripped = stripped[: -3]
    return stripped.strip()


def _generate_html(messages: list[dict]) -> str:
    client = _require_openai()
    response = client.chat.completions.create(
        model=BUILD_MODEL,
        messages=messages,
    )
    raw = response.choices[0].message.content or ""
    return _strip_html_fence(raw)


PLANNER_SYSTEM_PROMPT = """You are the Junie planner inside ArcReact, a JetBrains AR-native IDE. The user has spoken or typed a request. Before any code is written, you produce a tight execution plan that JARVIS will read aloud and the user must confirm.

Return ONLY a single JSON object — no markdown, no prose, no fences. Schema:

{
  "summary": "1–2 sentences. Plain English. What you'll build, in concrete terms. JARVIS speaks this verbatim.",
  "steps": [
    { "index": 1, "action": "<short verb phrase>", "target": "<file or component>", "why": "<one sentence>" },
    ...
  ],
  "expanded_prompt": "A detailed brief that /api/build will receive after the user confirms. This is the HIDDEN prompt — write it like a senior PM handing a task to an LLM. Include: (a) the user's literal intent restated, (b) section breakdown with content tone, (c) layout & component breakdown, (d) accent color (one of blue-500 / emerald-500 / orange-500 — pick what fits the request), (e) imagery suggestions (Unsplash topic keywords), (f) typography mood (one Google Font from: DM Sans, Plus Jakarta Sans, Sora, Outfit, Manrope), (g) any specific micro-interactions or animations that would elevate it. End with: 'Render as a single self-contained HTML file using React 18 + Tailwind via CDN per the build system rules.'"
}

Plan rules:
- 3 to 6 steps. Each step is a concrete action a coder would take.
- target should look like a path: "index.html · hero", "index.html · pricing-grid", "components/CTA".
- The summary must be honest about what the page will be — don't oversell.
- expanded_prompt must be 4–10 sentences and READS LIKE A REAL CREATIVE BRIEF, not bullet points.

If the user is asking for a modification (current_code provided), the plan is the diff: which sections change, what stays. The expanded_prompt then ends with: 'Apply the change to the existing HTML; preserve everything not affected.'"""


@app.post("/api/plan", response_model=PlanResponse)
def api_plan(payload: PlanRequest) -> PlanResponse:
    if not payload.prompt.strip():
        raise HTTPException(400, "prompt cannot be empty")

    client = _require_openai()
    user_block = f"User request: {payload.prompt.strip()}"
    if payload.current_code and payload.current_code.strip():
        # Truncate to keep planner fast — full code goes to /api/build later.
        clipped = payload.current_code.strip()
        if len(clipped) > 6000:
            clipped = clipped[:6000] + "\n... [truncated]"
        user_block += f"\n\nExisting HTML (truncated for planning):\n{clipped}"

    response = client.chat.completions.create(
        model=BUILD_MODEL,
        messages=[
            {"role": "system", "content": PLANNER_SYSTEM_PROMPT},
            {"role": "user", "content": user_block},
        ],
        response_format={"type": "json_object"},
    )
    raw = response.choices[0].message.content or "{}"
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise HTTPException(502, f"planner returned invalid JSON: {exc}") from exc

    summary = (data.get("summary") or "").strip()
    expanded = (data.get("expanded_prompt") or "").strip()
    if not summary or not expanded:
        raise HTTPException(502, "planner response missing summary or expanded_prompt")

    raw_steps = data.get("steps") or []
    steps: list[PlanStep] = []
    for idx, item in enumerate(raw_steps, start=1):
        if not isinstance(item, dict):
            continue
        steps.append(
            PlanStep(
                index=int(item.get("index", idx)),
                action=str(item.get("action", "")).strip() or "Edit",
                target=str(item.get("target", "")).strip() or "index.html",
                why=str(item.get("why", "")).strip(),
            )
        )

    return PlanResponse(
        summary=summary,
        steps=steps,
        expanded_prompt=expanded,
        success=True,
    )


@app.post("/api/build", response_model=BuildResponse)
def api_build(payload: BuildRequest) -> BuildResponse:
    if not payload.prompt.strip():
        raise HTTPException(400, "prompt cannot be empty")

    html = _generate_html(
        [
            {"role": "system", "content": BUILD_SYSTEM_PROMPT},
            {"role": "user", "content": payload.prompt},
        ]
    )
    return BuildResponse(html=html, success=True)


@app.post("/api/modify", response_model=BuildResponse)
def api_modify(payload: ModifyRequest) -> BuildResponse:
    if not payload.prompt.strip():
        raise HTTPException(400, "prompt cannot be empty")
    if not payload.current_code.strip():
        raise HTTPException(400, "current_code cannot be empty")

    user_content = (
        f"Modification request: {payload.prompt}\n\n"
        f"Current HTML:\n{payload.current_code}\n\n"
        "Return the complete modified HTML file. Preserve everything not affected by the request."
    )

    html = _generate_html(
        [
            {"role": "system", "content": BUILD_SYSTEM_PROMPT},
            {"role": "user", "content": user_content},
        ]
    )
    return BuildResponse(html=html, success=True)


@app.post("/api/modify-element", response_model=BuildResponse)
def api_modify_element(payload: ModifyElementRequest) -> BuildResponse:
    if not payload.prompt.strip():
        raise HTTPException(400, "prompt cannot be empty")
    if not payload.current_code.strip():
        raise HTTPException(400, "current_code cannot be empty")

    element_lines = []
    if payload.element.tag:
        element_lines.append(f"tag: {payload.element.tag}")
    if payload.element.class_:
        element_lines.append(f"class: {payload.element.class_}")
    if payload.element.text:
        element_lines.append(f"text: {payload.element.text}")
    element_block = "\n".join(element_lines) if element_lines else "(no element metadata provided)"

    user_content = (
        f"Modify ONLY the specific element described below. Leave every other element exactly as it is.\n\n"
        f"Target element:\n{element_block}\n\n"
        f"Modification request: {payload.prompt}\n\n"
        f"Current HTML:\n{payload.current_code}\n\n"
        "Return the complete modified HTML file."
    )

    html = _generate_html(
        [
            {"role": "system", "content": BUILD_SYSTEM_PROMPT},
            {"role": "user", "content": user_content},
        ]
    )
    return BuildResponse(html=html, success=True)


class CodeEditRequest(BaseModel):
    filename: str
    content: str
    previous_content: Optional[str] = None
    edit_type: Optional[str] = None
    description: Optional[str] = None


class CodeEditResponse(BaseModel):
    id: str
    filename: str
    content: str
    previous_content: Optional[str]
    edit_type: Optional[str]
    description: Optional[str]
    created_at: datetime


@app.post("/code-edits", response_model=CodeEditResponse)
async def add_code_edit(payload: CodeEditRequest):
    col = _require_code_edits_collection()
    doc = {
        "filename": payload.filename,
        "content": payload.content,
        "previous_content": payload.previous_content,
        "edit_type": payload.edit_type,
        "description": payload.description,
        "created_at": datetime.now(timezone.utc),
    }
    result = await col.insert_one(doc)
    return CodeEditResponse(id=str(result.inserted_id), **doc)


@app.get("/code-edits", response_model=list[CodeEditResponse])
async def list_code_edits(filename: Optional[str] = None):
    col = _require_code_edits_collection()
    query = {"filename": filename} if filename else {}
    docs = await col.find(query).sort("created_at", -1).to_list(length=None)
    return [CodeEditResponse(id=str(d["_id"]), **{k: v for k, v in d.items() if k != "_id"}) for d in docs]


@app.delete("/code-edits/{edit_id}")
async def delete_code_edit(edit_id: str):
    col = _require_code_edits_collection()
    try:
        oid = ObjectId(edit_id)
    except Exception:
        raise HTTPException(400, "Invalid edit id")
    result = await col.delete_one({"_id": oid})
    if result.deleted_count == 0:
        raise HTTPException(404, "Code edit not found")
    return {"deleted": edit_id}


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