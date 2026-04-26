from __future__ import annotations

import base64
import json
import math
import os
import re
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional, Union

import certifi
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
import templates as template_registry

load_dotenv()

app = FastAPI(title="AETHER Ghost Pair Programmer")

GHOST_REPLY_VOICE_ID = "lUTamkMw7gOzZbFIwmq4"

EMBEDDING_MODEL = "text-embedding-3-large"
VISION_MODEL = "gpt-4o"
# gpt-4o is ~3x faster than the gpt-5 family for the same React/Tailwind
# output quality, and the multi-file JSON build was taking 90s+ before.
# Override with `BUILD_MODEL` env var to switch back to a slower model.
BUILD_MODEL = os.getenv("BUILD_MODEL", "gpt-4o")
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

ROUTER_MODEL = os.getenv("ROUTER_MODEL", "gpt-4o")


def _make_template_router_prompt():
    """Build the router system prompt dynamically from the registry."""
    template_list = template_registry.list_for_router()
    template_docs = "\n\n".join(
        f"Template: {t['id']}\n"
        f"Description: {t['description']}\n"
        f"Spec slots: {t['spec']}"
        for t in template_list
    )
    return f"""You are a template selector for a website builder. The user has described a website they want to build.

Your job: pick the best matching template from our registry, OR say "none" if no template is appropriate.

Available templates:

{template_docs}

Respond with ONLY a JSON object, no other text:
- If a template matches (≥70% confidence): {{"template_id": "template_name", "spec": {{...spec object...}}}}
- If no template matches: {{"template_id": "none"}}

When you pick a template:
1. Set spec slots to sensible defaults based on the user's description
2. Use real product/company names from the request, or provide plausible examples
3. For images, use Unsplash keywords in SPEC_SCHEMA_HINT fields (model will fill them)
4. Ensure every required slot in the spec is set (fallback to good defaults if not provided)

Example: User says "I need a landing page for my SaaS product called LineFlow".
Response: {{"template_id": "saas_landing", "spec": {{"product_name": "LineFlow", "tagline": "Ship faster, scale smarter", ...}}}}"""


openai_client = OpenAI(api_key=os.getenv("OPENAI_API_KEY")) if os.getenv("OPENAI_API_KEY") else None

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Local dev keeps generated audio next to the package; Vercel functions
# only have a writable /tmp, so fall back there if mkdir hits a read-only
# fs. Either way the StaticFiles mount points at the writable copy.
generated_dir = Path(__file__).resolve().parent / "aether_voice" / "generated"
try:
    generated_dir.mkdir(parents=True, exist_ok=True)
except OSError:
    generated_dir = Path("/tmp/aether_generated")
    generated_dir.mkdir(parents=True, exist_ok=True)
app.mount("/generated", StaticFiles(directory=str(generated_dir)), name="generated")


@app.on_event("startup")
async def startup():
    mongo_uri = os.getenv("MONGODB_URI")
    if mongo_uri:
        # tlsCAFile pins to the certifi bundle — the system OpenSSL on
        # Python 3.14 / macOS otherwise fails the Atlas TLS handshake with
        # `TLSV1_ALERT_INTERNAL_ERROR`. serverSelectionTimeoutMS keeps the
        # request from hanging for 30s if the cluster is unreachable.
        app.state.mongo = AsyncIOMotorClient(
            mongo_uri,
            tlsCAFile=certifi.where(),
            serverSelectionTimeoutMS=8000,
        )
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
    # New multi-file shape — full project map + which file the user is in.
    # `current_code` kept for backwards-compat with older clients that still
    # send a single HTML string.
    files: Optional[dict[str, str]] = None
    primary: Optional[str] = None
    current_code: Optional[str] = None


class ElementContext(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    tag: Optional[str] = None
    class_: Optional[str] = Field(default=None, alias="class")
    text: Optional[str] = None


class ModifyElementRequest(BaseModel):
    prompt: str
    files: Optional[dict[str, str]] = None
    primary: Optional[str] = None
    current_code: Optional[str] = None
    element: ElementContext


class BuildResponse(BaseModel):
    """Multi-file project response.

    `files` is the entire project keyed by repo-relative path; `primary` is
    what the editor should open first; `preview_html` is a self-contained
    HTML page the iOS WKWebView can render directly (Babel-standalone wrap of
    the JSX, or a generated docs page for backend stacks); `stack` is one of
    "react-vite" | "express" | "fastapi" | "html".

    Legacy `html` field is filled with `preview_html` so old clients keep
    working until they upgrade.
    """
    files: dict[str, str]
    primary: str
    preview_html: str
    stack: str
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


PROJECT_BUILD_SYSTEM_PROMPT = """You are a world-class designer + senior engineer building shippable, beautiful sites. The user is on a phone — no terminal, no npm. They want a real multi-file project they could push to GitHub AND a polished preview that renders in a WebView.

Stack from prompt:
- UI / landing / portfolio / dashboard → react-vite
- API / backend / server → express
- FastAPI / python backend → fastapi
- single static page → html

Return ONLY this JSON (no markdown, no prose):
{
  "stack": "react-vite" | "express" | "fastapi" | "html",
  "primary": "<path to open first>",
  "files": { "<path>": "<content>", ... }
}

(Note: do NOT emit preview_html — the server builds it from your files.)

==================== REACT-VITE PROJECTS ====================
Required files:
  - package.json  (vite, react@18, react-dom@18; scripts: dev=vite, build=vite build)
  - vite.config.js
  - index.html  (Vite root, has <div id="root"> and <script type="module" src="/src/main.jsx">)
  - src/main.jsx  (createRoot from react-dom/client; import App from './App.jsx')
  - src/App.jsx  (the page — ONE file with all sections inline, OR App.jsx + components/*.jsx)
  - src/index.css  (Tailwind CDN is loaded by the preview; you can also add raw CSS here)
  - README.md
primary = "src/App.jsx".

CRITICAL JSX RULES (the preview server inlines all your .jsx files into one Babel-standalone script — so):
  - DO NOT use ES module import paths the browser can't resolve at runtime. The server strips imports/exports automatically. So your code must work when ALL imports are removed and every `export default Foo` becomes plain `function Foo`.
  - Use plain function declarations: `function Hero() { return ... }`, `function App() { return <><Hero /><Pricing /></> }`. No `export default`. Don't rely on `import { useState } from 'react'` — use `const { useState, useEffect } = React;` at the top of App.jsx, OR use `React.useState` directly.
  - Your `src/App.jsx` MUST end with `function App() { ... }` that renders the full page. The preview bundler calls `<App />`.
  - Tailwind classes work — the preview loads `https://cdn.tailwindcss.com`. Use them aggressively.
  - For images, use real Unsplash URLs: `https://images.unsplash.com/photo-{ID}?w=1600&q=80&auto=format&fit=crop`. Never use `placeholder` or empty `src`.

==================== DESIGN BAR (read this twice) ====================
Your output gets compared to vercel.com, linear.app, stripe.com, ramp.com, and apple.com. Hit that bar.
- Type: huge headlines (text-6xl / text-7xl / text-8xl tracking-tight font-semibold). Body text-lg leading-relaxed. Use one Google Font: SF Pro / Inter / DM Sans / Plus Jakarta Sans / Sora.
- Color: dark theme by default. bg-neutral-950 page, bg-neutral-900 cards, text-white headings, text-neutral-400 body. ONE accent color (sky-500 / emerald-500 / orange-500). NO rainbow, NO neon.
- Layout: max-w-7xl mx-auto px-6. Sections py-24 / py-32. Grids gap-8 / gap-12. Real visual hierarchy — not a stack of identical cards.
- Components: rounded-2xl, border border-neutral-800, hover:border-neutral-700, soft shadows.
- Imagery: every section that COULD have a photo SHOULD have a photo (Unsplash). Hero gets a hero image or a product mock. No empty whitespace blocks. No `<img />` without a real src.
- Copy: write real compelling product copy, not "Lorem ipsum" or generic placeholder text. If it's "Apple-style", write the kind of copy Apple would write.
- Motion: use `transition`, `hover:scale-105`, `duration-300` on cards / buttons.
- Accessibility: every button is real (`<button>`), every link is `<a>`, alt text on images.

==================== EXPRESS ====================
package.json (express + cors), server.js (app.listen(3000), example routes), routes/*.js, .env.example, README.md.
primary = "server.js".

==================== FASTAPI ====================
main.py (FastAPI + uvicorn), requirements.txt, routers/*.py, .env.example, README.md.
primary = "main.py".

==================== HTML ====================
One index.html. primary = "index.html".

Return ONLY the JSON object. No markdown fences. No commentary."""


def _generate_project(messages: list[dict]) -> dict:
    """Run the JSON-mode multi-file project generator. Returns the parsed
    dict so callers can wrap it as a `BuildResponse` (with backwards-compat
    `html` aliasing `preview_html` for legacy iOS clients).
    """
    client = _require_openai()
    response = client.chat.completions.create(
        model=BUILD_MODEL,
        messages=messages,
        response_format={"type": "json_object"},
    )
    raw = response.choices[0].message.content or "{}"
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise HTTPException(502, f"build returned invalid JSON: {exc}") from exc
    return data


def _build_response_from_project(data: dict) -> BuildResponse:
    files = data.get("files") or {}
    if not isinstance(files, dict) or not files:
        raise HTTPException(502, "build response missing files")
    # Normalize: every value must be a string.
    files = {str(k): str(v) for k, v in files.items()}
    primary = data.get("primary") or _pick_primary(files)
    if primary not in files:
        primary = _pick_primary(files)
    stack = data.get("stack") or "react-vite"

    # Build preview_html from the project files server-side. Models often
    # emit a preview that contains `import` statements (or skip the preview
    # entirely), which makes Babel-standalone fail and the user sees a
    # half-rendered white page with placeholder boxes. By bundling here we
    # guarantee a working render regardless of model output.
    if stack == "react-vite":
        preview_html = _bundle_react_preview(files)
    elif stack == "html":
        preview_html = files.get("index.html") or data.get("preview_html") or _docs_page(files, stack)
    else:
        # Backend stacks: model-supplied preview if any, else generated docs.
        preview_html = data.get("preview_html") or _docs_page(files, stack)

    return BuildResponse(
        files=files,
        primary=primary,
        preview_html=preview_html,
        stack=stack,
        html=preview_html,  # legacy alias
        success=True,
    )


# Matches single-line and multi-line `import … ;` statements. The DOTALL
# flag lets the body span newlines (`import { useState,\n  useEffect } from
# 'react';` was the silent killer — the previous single-line regex left
# half a destructure behind, Babel choked, the whole preview went black).
_IMPORT_RE = re.compile(r'^[ \t]*import\b[^;]*?;[ \t]*\n?', re.MULTILINE | re.DOTALL)
# Bare side-effect imports without a semicolon: `import './app.css'`
_IMPORT_BARE_RE = re.compile(r'^[ \t]*import\s+[\'"][^\'"]+[\'"][ \t]*\n', re.MULTILINE)
_EXPORT_DEFAULT_RE = re.compile(r'^\s*export\s+default\s+', re.MULTILINE)
_EXPORT_NAMED_RE = re.compile(r'^\s*export\s+(?=(?:const|let|var|function|class|async)\s)', re.MULTILINE)
_EXPORT_BRACE_RE = re.compile(r'^\s*export\s*\{[^}]*\}\s*;?\s*\n?', re.MULTILINE)
# `export default Foo;` where Foo is just an identifier — strip whole line
# (leaving a bare `Foo;` that strips to nothing useful).
_EXPORT_DEFAULT_IDENT_RE = re.compile(r'^\s*export\s+default\s+\w+\s*;?\s*\n?', re.MULTILINE)


def _strip_es_modules(src: str) -> str:
    """Remove ES-module syntax so the body works inside a single
    Babel-standalone <script type="text/babel"> block. Handles multi-line
    imports, bare side-effect imports (`import './foo.css'`), and every
    flavor of export.
    """
    src = _IMPORT_RE.sub('', src)
    src = _IMPORT_BARE_RE.sub('', src)
    src = _EXPORT_DEFAULT_IDENT_RE.sub('', src)
    src = _EXPORT_BRACE_RE.sub('', src)
    src = _EXPORT_DEFAULT_RE.sub('', src)
    src = _EXPORT_NAMED_RE.sub('', src)
    return src


def _bundle_react_preview(files: dict[str, str]) -> str:
    """Concatenate every JSX/TSX file in the project (after stripping ES
    module syntax) into one Babel-standalone bundle. Order: components
    first (so they're declared before App), then App last. Tailwind CDN +
    React 18 + ReactDOM 18 + Babel are loaded in <head>.
    """
    jsx_files = sorted(
        [(p, c) for p, c in files.items()
         if p.endswith(('.jsx', '.tsx', '.js')) and 'src/' in p],
        key=lambda pc: (
            # App.jsx last so functions it references are already declared.
            1 if pc[0].endswith(('App.jsx', 'App.tsx')) else 0,
            # main.jsx after components but before App is fine; we drop it
            # below anyway since main.jsx just calls createRoot.
            pc[0],
        ),
    )

    # Drop main.jsx — it only does `createRoot(...).render(<App />)`, which
    # we re-emit at the bottom of the bundle. Keeping it would cause a
    # double-render or a reference error.
    jsx_files = [(p, c) for p, c in jsx_files
                 if not p.endswith(('main.jsx', 'main.tsx'))]

    bundled = "\n\n".join(
        f"// === {path} ===\n{_strip_es_modules(content)}"
        for path, content in jsx_files
    )
    # Escape any literal `</script>` so it can't prematurely close our
    # `<script id="__user_jsx" type="text/plain">` envelope. Models do
    # occasionally emit raw `</script>` in JSX strings.
    bundled = bundled.replace("</script>", "<\\/script>")

    # CSS the model wrote — inline it. Tailwind handles 90% of styling but
    # raw rules (e.g. custom keyframes) belong on the page.
    css_blocks = "\n".join(
        files[p] for p in ("src/index.css", "src/App.css")
        if p in files
    )

    return f"""<!DOCTYPE html>
<html lang="en" class="dark">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1" />
<title>Preview</title>
<!-- Configure Tailwind BEFORE its script loads so dark mode + safelist
     classes are JIT-compiled even if the model uses them dynamically. -->
<script>
  window.tailwind = window.tailwind || {{}};
  window.tailwind.config = {{
    darkMode: 'class',
    theme: {{
      extend: {{
        fontFamily: {{
          sans: ['Inter', 'system-ui', 'sans-serif'],
          display: ['Plus Jakarta Sans', 'Inter', 'sans-serif'],
        }},
      }},
    }},
  }};
</script>
<!-- IMPORTANT: do NOT add `crossorigin="anonymous"` to these tags.
     `cdn.tailwindcss.com` returns a 302 redirect without CORS headers, so
     the browser refuses to execute the response when `crossorigin` is set
     and Tailwind never runs (= no classes get styled). We don't need
     crossorigin for error visibility either: our wrapper below uses direct
     eval() in a same-origin inline script, so any thrown error has a
     readable message + stack regardless of CDN script origin. -->
<script src="https://cdn.tailwindcss.com"></script>
<script src="https://unpkg.com/react@18/umd/react.production.min.js"></script>
<script src="https://unpkg.com/react-dom@18/umd/react-dom.production.min.js"></script>
<script src="https://unpkg.com/@babel/standalone/babel.min.js"></script>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800;900&family=Plus+Jakarta+Sans:wght@400;500;600;700;800&display=swap" rel="stylesheet">
<style>
  /* Base dark-theme fallback so the page still looks intentional even if
     Tailwind hasn't finished JIT'ing user-supplied classes. */
  :root {{ color-scheme: dark; --bg: #0a0a0a; --fg: #fafafa; --muted: #a3a3a3; --card: #171717; --border: #262626; --accent: #38bdf8; }}
  *, *::before, *::after {{ box-sizing: border-box; }}
  html, body {{ margin: 0; padding: 0; background: var(--bg); color: var(--fg); font-family: 'Inter', system-ui, sans-serif; -webkit-font-smoothing: antialiased; }}
  img {{ max-width: 100%; height: auto; display: block; }}
  a {{ color: inherit; text-decoration: none; }}
  button {{ cursor: pointer; }}
  /* user CSS */
{css_blocks}
</style>
</head>
<body class="bg-neutral-950 text-neutral-50">
<div id="root"></div>
<script>
  // Global error handler to capture cross-origin script errors that would
  // otherwise show as "Script error." with no details. This handler surfaces
  // the real error message + stack in the UI and console.
  window.__errors = [];
  window.addEventListener('error', function(event) {{
    const msg = (event && event.message) || event;
    const stack = (event && event.error && event.error.stack) || '';
    const info = msg + (stack ? '\\n' + stack : '');
    window.__errors.push(info);
    console.error('GLOBAL ERROR HANDLER:', info);
    // Paint the error into #root if it happens before Babel/React loads
    const root = document.getElementById('root');
    if (root && root.children.length === 0) {{
      root.innerHTML = '<pre style="padding:24px;color:#f87171;font:12px ui-monospace,monospace;white-space:pre-wrap;background:#0a0a0a">Preview error:\\n' + info + '</pre>';
    }}
  }}, true);
</script>
<!--
  User JSX as plain text — NOT auto-compiled by Babel. We compile + eval
  inline below so any compile or runtime error is thrown from THIS inline
  script (same-origin), giving us a real message + stack instead of the
  cross-origin-sanitized "Script error." Babel-standalone normally evals
  inside its own script context which makes the resulting errors opaque.
-->
<script id="__user_jsx" type="text/plain">
{bundled}
</script>
<script>
  (function () {{
    const __mount = document.getElementById('root');
    function __formatErr(err) {{
      if (!err) return String(err);
      const parts = [];
      if (err.message) parts.push(err.message);
      if (err.name && err.name !== 'Error' && !err.message)
        parts.push(err.name);
      if (err.stack) parts.push(err.stack);
      if (parts.length === 0) {{
        try {{ parts.push(JSON.stringify(err, null, 2)); }} catch (_) {{ parts.push(String(err)); }}
      }}
      return parts.join('\\n');
    }}
    function __paintError(label, err) {{
      const msg = __formatErr(err);
      console.error(label + ':', msg);
      __mount.innerHTML =
        '<pre style="padding:24px;color:#f87171;font:12px ui-monospace,monospace;white-space:pre-wrap;background:#0a0a0a">' +
        label + ':\\n' + msg.replace(/[<&]/g, function(c){{return c==='<'?'&lt;':'&amp;';}}) +
        '</pre>';
    }}

    // Hoist common React hooks at the script's top level so direct `eval`
    // below sees them in scope. We can't pass them as Function args because
    // `new Function` strips source-map info from runtime errors; eval keeps
    // it (with a sourceURL directive) so stack traces show user-jsx.js:LINE.
    const React = window.React;
    const ReactDOM = window.ReactDOM;
    if (!React || !ReactDOM) {{
      __paintError('React CDN failed to load', new Error('window.React or window.ReactDOM is undefined'));
      return;
    }}
    const {{ useState, useEffect, useRef, useMemo, useCallback,
             useLayoutEffect, useReducer, useContext, useId,
             createContext, forwardRef, memo, Fragment }} = React;
    const ReactDOMClient = ReactDOM;

    const src = document.getElementById('__user_jsx').textContent;

    // Compile JSX → plain JS via Babel-standalone. Compile errors land here
    // with the real Babel message (line/column/snippet).
    let compiled;
    try {{
      if (!window.Babel) throw new Error('Babel-standalone failed to load');
      compiled = window.Babel.transform(src, {{
        presets: [['react', {{ runtime: 'classic' }}]],
        sourceType: 'script',
      }}).code;
    }} catch (err) {{
      __paintError('Babel compile failed', err);
      return;
    }}

    // Direct `eval` (NOT `new Function`) so:
    //   1. Stack traces preserve real line numbers
    //   2. The `//# sourceURL=user-jsx.js` directive makes WebKit attribute
    //      errors to that synthetic file in devtools and stack frames
    //   3. The user's components run in the same scope as our hoisted
    //      React/hooks, so they don't need imports
    // A small post-fix copies any top-level `App` ref into a window slot so
    // we can read it back out here; const-in-eval doesn't leak otherwise.
    //
    // IMPORTANT: do NOT declare a local `App` in this scope — Safari's eval
    // throws "Can't create duplicate variable" when the eval'd code contains
    // `function App()` or `const App = …` and the same name already exists
    // in the calling scope.
    let __ResolvedApp;
    try {{
      const augmented =
        compiled +
        '\\n;try {{ if (typeof App !== "undefined") window.__APP_REF = App; }} catch(_){{}}' +
        '\\n//# sourceURL=user-jsx.js';
      delete window.__APP_REF;
      // eslint-disable-next-line no-eval
      eval(augmented);
      __ResolvedApp = window.__APP_REF;
      delete window.__APP_REF;
    }} catch (err) {{
      __paintError('JSX eval failed', err);
      return;
    }}

    if (typeof __ResolvedApp !== 'function') {{
      __paintError('App not found',
        new Error('Bundled source did not declare a top-level `App` component.'));
      return;
    }}

    try {{
      const node = React.createElement(__ResolvedApp);
      if (ReactDOMClient.createRoot) {{
        ReactDOMClient.createRoot(__mount).render(node);
      }} else {{
        ReactDOMClient.render(node, __mount);
      }}
    }} catch (err) {{
      __paintError('React render crashed', err);
    }}
  }})();
</script>
</body>
</html>"""


def _pick_primary(files: dict[str, str]) -> str:
    for candidate in ("src/App.jsx", "src/App.tsx", "src/main.jsx", "App.jsx",
                      "server.js", "main.py", "index.html"):
        if candidate in files:
            return candidate
    return next(iter(sorted(files.keys())), "index.html")


def _docs_page(files: dict[str, str], stack: str) -> str:
    items = "".join(f"<li><code>{p}</code></li>" for p in sorted(files.keys())[:30])
    return (
        '<!DOCTYPE html><html><head><meta charset="utf-8">'
        f'<title>{stack} project</title>'
        '<style>body{font-family:-apple-system,BlinkMacSystemFont,Inter,sans-serif;'
        'background:#1e1f22;color:#bcbec4;padding:32px;margin:0}'
        'h1{font-size:18px;color:#fff;margin:0 0 4px}'
        'p{font-size:13px;color:#9ea1a8}'
        'ul{font-size:12px;line-height:1.6;color:#d5d7db;list-style:none;padding-left:0;margin-top:16px}'
        'code{background:#2b2d30;padding:2px 6px;border-radius:4px;color:#5fb865}</style>'
        '</head><body>'
        f'<h1>{stack} project ready</h1>'
        '<p>Backend stacks don\'t run in the preview pane — push to GitHub to deploy.</p>'
        f'<ul>{items}</ul></body></html>'
    )


PLANNER_SYSTEM_PROMPT = """You are the Junie planner inside ArcReact, a JetBrains AR-native IDE. The user has spoken or typed a request. Before any code is written, you produce a tight execution plan that JARVIS will read aloud and the user must confirm.

ArcReact builds REAL multi-file projects, not single HTML pages. The build step that runs after this plan is approved produces a complete project tree (package.json, vite.config.js, src/App.jsx, etc. for React; or server.js, routes/, package.json for Express; or main.py, requirements.txt for FastAPI). Plan accordingly.

Pick a stack from the prompt:
- "landing page", "marketing site", "portfolio", "dashboard", anything UI → react-vite (Vite + React 18)
- "API", "backend", "server", "REST" → express (Node + Express)
- "FastAPI", "python backend" → fastapi (FastAPI + uvicorn)
- "blog", "static site", "single page" → html (one index.html)

Return ONLY a single JSON object — no markdown, no prose, no fences. Schema:

{
  "summary": "1–2 sentences. Plain English. What you'll build AND the stack you'll use (e.g. 'I'll scaffold a React + Vite landing page for…'). JARVIS speaks this verbatim.",
  "steps": [
    { "index": 1, "action": "<short verb phrase>", "target": "<file or component>", "why": "<one sentence>" },
    ...
  ],
  "expanded_prompt": "A detailed brief that /api/build will receive after the user confirms. This is the HIDDEN prompt — write it like a senior PM handing a task to an LLM. Include: (a) the user's literal intent restated, (b) the chosen stack, (c) section/route breakdown with tone, (d) layout & component breakdown for UI projects, (e) accent color (blue-500 / emerald-500 / orange-500 — pick what fits) for UI projects, (f) imagery suggestions (Unsplash topic keywords) for UI projects, (g) typography mood (one Google Font from: DM Sans, Plus Jakarta Sans, Sora, Outfit, Manrope) for UI projects, (h) any specific micro-interactions or animations that would elevate it. End with: 'Return a complete multi-file project as JSON per the build system rules — every file must be present.'"
}

Plan rules:
- 3 to 6 steps. Each step is a concrete action a coder would take.
- target should be a real repo-relative path the build will write, e.g.:
    React: "package.json", "src/App.jsx", "src/main.jsx", "src/index.css", "index.html"
    Express: "package.json", "server.js", "routes/items.js", ".env.example"
    FastAPI: "main.py", "requirements.txt", "routers/items.py"
- The summary MUST name the stack so the user knows what they're getting (not "single-page implementation").
- expanded_prompt must be 4–10 sentences and READS LIKE A REAL CREATIVE BRIEF.

If the user is asking for a modification (files+primary or current_code provided), the plan is the diff: which files change, what stays. expanded_prompt then ends with: 'Edit only what's necessary; return the complete updated project so the IDE can replace it atomically.'"""


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


def _build_via_template(prompt: str) -> Optional[dict]:
    """Try to route the prompt to a template. Returns a BuildResponse-ready dict
    (files, primary, preview_html, stack) or None if no template fits.
    """
    try:
        client = _require_openai()
        router_prompt = _make_template_router_prompt()
        response = client.chat.completions.create(
            model=ROUTER_MODEL,
            messages=[
                {"role": "system", "content": router_prompt},
                {"role": "user", "content": prompt},
            ],
            response_format={"type": "json_object"},
        )
        raw = response.choices[0].message.content or "{}"
        route_result = json.loads(raw)
    except (json.JSONDecodeError, Exception):
        return None

    template_id = route_result.get("template_id", "none")
    if template_id == "none":
        return None

    # Look up template module
    tmpl = template_registry.get(template_id)
    if not tmpl:
        return None

    # Extract spec
    spec = route_result.get("spec") or {}
    if not isinstance(spec, dict):
        spec = {}

    # Render the template
    try:
        files = tmpl.render(spec)
    except Exception:
        return None

    if not files or not isinstance(files, dict):
        return None

    return {
        "files": files,
        "primary": "src/App.jsx",
        "stack": "react-vite",
    }


@app.post("/api/build", response_model=BuildResponse)
def api_build(payload: BuildRequest) -> BuildResponse:
    if not payload.prompt.strip():
        raise HTTPException(400, "prompt cannot be empty")

    # Try template router first — it's fast and produces beautiful, consistent output
    template_result = _build_via_template(payload.prompt)
    if template_result:
        data = template_result
        return _build_response_from_project(data)

    # Fall back to freeform LLM codegen if no template matched
    data = _generate_project(
        [
            {"role": "system", "content": PROJECT_BUILD_SYSTEM_PROMPT},
            {"role": "user", "content": payload.prompt},
        ]
    )
    return _build_response_from_project(data)


@app.post("/api/modify", response_model=BuildResponse)
def api_modify(payload: ModifyRequest) -> BuildResponse:
    if not payload.prompt.strip():
        raise HTTPException(400, "prompt cannot be empty")

    # Build a "current project" payload — preferring the new files+primary
    # shape, but falling back to the legacy single-HTML field so older clients
    # keep working until they upgrade.
    if payload.files and payload.primary:
        files_blob = json.dumps(payload.files)
        user_content = (
            f"CURRENT PROJECT (primary = {payload.primary}):\n{files_blob}\n\n"
            f"REQUESTED CHANGE:\n{payload.prompt}\n\n"
            "Return the COMPLETE updated project as JSON in the same shape."
        )
    elif payload.current_code and payload.current_code.strip():
        user_content = (
            f"CURRENT PROJECT (single index.html):\n{payload.current_code}\n\n"
            f"REQUESTED CHANGE:\n{payload.prompt}\n\n"
            "Return the COMPLETE updated project as JSON. If the change warrants splitting "
            "into a multi-file React project, do that — otherwise keep it single-file."
        )
    else:
        raise HTTPException(400, "modify requires either files+primary or current_code")

    data = _generate_project(
        [
            {"role": "system", "content": PROJECT_BUILD_SYSTEM_PROMPT
                + "\n\nCONTEXT: This is a MODIFICATION. Preserve existing stack, layout, design language, and component structure. Edit only what's necessary."},
            {"role": "user", "content": user_content},
        ]
    )
    return _build_response_from_project(data)


@app.post("/api/modify-element", response_model=BuildResponse)
def api_modify_element(payload: ModifyElementRequest) -> BuildResponse:
    if not payload.prompt.strip():
        raise HTTPException(400, "prompt cannot be empty")

    element_lines = []
    if payload.element.tag:
        element_lines.append(f"tag: {payload.element.tag}")
    if payload.element.class_:
        element_lines.append(f"class: {payload.element.class_}")
    if payload.element.text:
        element_lines.append(f"text: {payload.element.text}")
    element_block = "\n".join(element_lines) if element_lines else "(no element metadata provided)"

    if payload.files and payload.primary:
        project_blob = json.dumps(payload.files)
        scope = f"primary = {payload.primary}"
    elif payload.current_code and payload.current_code.strip():
        project_blob = payload.current_code
        scope = "single index.html"
    else:
        raise HTTPException(400, "modify-element requires either files+primary or current_code")

    user_content = (
        f"Modify ONLY the element described below. Leave every other element exactly as it is.\n\n"
        f"Target element:\n{element_block}\n\n"
        f"Modification request: {payload.prompt}\n\n"
        f"CURRENT PROJECT ({scope}):\n{project_blob}\n\n"
        "Return the COMPLETE updated project as JSON in the same shape."
    )

    data = _generate_project(
        [
            {"role": "system", "content": PROJECT_BUILD_SYSTEM_PROMPT},
            {"role": "user", "content": user_content},
        ]
    )
    return _build_response_from_project(data)


class AnalyzeRequest(BaseModel):
    files: dict[str, str]
    question: str


class AnalyzeResponse(BaseModel):
    response: str
    success: bool


# Hard cap so we never blow past the model context window. We slice each
# file independently rather than the whole bundle so the most relevant
# files (App.jsx, etc.) get full content rather than being truncated last.
_ANALYZE_FILE_CHAR_CAP = 8000
_ANALYZE_TOTAL_CHAR_CAP = 40000


def _pack_files_for_analyze(files: dict[str, str]) -> str:
    """Format the project as one prompt blob: `=== path ===\n<body>` per
    file, truncating overly large files and the whole pack if needed."""
    parts: list[str] = []
    used = 0
    for path in sorted(files.keys()):
        body = files[path] or ""
        if len(body) > _ANALYZE_FILE_CHAR_CAP:
            body = body[:_ANALYZE_FILE_CHAR_CAP] + "\n... [truncated]"
        chunk = f"=== {path} ===\n{body}\n"
        if used + len(chunk) > _ANALYZE_TOTAL_CHAR_CAP:
            parts.append("... [remaining files omitted to fit context]\n")
            break
        parts.append(chunk)
        used += len(chunk)
    return "\n".join(parts)


@app.post("/api/analyze", response_model=AnalyzeResponse)
def analyze_project(payload: AnalyzeRequest):
    """Generic project Q&A — feed every file + a free-form question to GPT
    and return the plain-text answer. Used by AR voice queries ("what does
    Login do?"), AR code review (rates quality/security/perf/a11y), and
    cross-file lookups. Plain string output; callers parse if they need
    structure."""
    if not payload.files:
        raise HTTPException(400, "no files provided")
    if not (payload.question or "").strip():
        raise HTTPException(400, "question is empty")

    client = _require_openai()
    project_blob = _pack_files_for_analyze(payload.files)
    system = (
        "You are a senior software engineer reviewing a multi-file project. "
        "Answer the user's question precisely using ONLY the files provided. "
        "If you cite a file, use its path. If you cite a line, include the "
        "line number. Be concise — no preamble, no apology, no markdown "
        "fences unless they would actually be code. Plain text by default."
    )
    user = f"PROJECT FILES:\n\n{project_blob}\n\nQUESTION:\n{payload.question}"
    response = client.chat.completions.create(
        model=BUILD_MODEL,
        messages=[
            {"role": "system", "content": system},
            {"role": "user",   "content": user},
        ],
        temperature=0.3,
        max_tokens=900,
    )
    text = (response.choices[0].message.content or "").strip()
    return AnalyzeResponse(response=text, success=True)


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
async def list_code_edits(
    filename: Optional[str] = None,
    source: Optional[str] = None,
    since: Optional[str] = None,
):
    col = _require_code_edits_collection()
    query: dict = {}
    if filename:
        query["filename"] = filename
    if source:
        query["edit_type"] = source
    if since:
        try:
            since_dt = datetime.fromisoformat(since.replace("Z", "+00:00"))
            query["created_at"] = {"$gt": since_dt}
        except Exception:
            pass
    docs = await col.find(query).sort("created_at", 1).to_list(length=None)
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