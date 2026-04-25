import os
import base64
import math
from datetime import datetime, timezone
from dotenv import load_dotenv

load_dotenv()

from fastapi import FastAPI, File, UploadFile, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import Response
from pydantic import BaseModel
from openai import OpenAI
from motor.motor_asyncio import AsyncIOMotorClient
from bson import ObjectId

app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

openai_client = OpenAI(api_key=os.environ["OPENAI_API_KEY"])

EMBEDDING_MODEL = "text-embedding-3-large"
VISION_MODEL = "gpt-4o"
DB_NAME = "mobileide"
COLLECTION = "images"


@app.on_event("startup")
async def startup():
    app.state.mongo = AsyncIOMotorClient(os.environ["MONGODB_URI"])
    app.state.col = app.state.mongo[DB_NAME][COLLECTION]


@app.on_event("shutdown")
async def shutdown():
    app.state.mongo.close()


# ── models ────────────────────────────────────────────────────────────────────

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


# ── helpers ───────────────────────────────────────────────────────────────────

def image_to_data_url(data: bytes, content_type: str) -> str:
    return f"data:{content_type};base64,{base64.b64encode(data).decode()}"


def describe_image(data_url: str) -> str:
    response = openai_client.chat.completions.create(
        model=VISION_MODEL,
        messages=[{
            "role": "user",
            "content": [
                {"type": "image_url", "image_url": {"url": data_url, "detail": "high"}},
                {"type": "text", "text": (
                    "Describe this image in rich detail, covering objects, colors, "
                    "scene, mood, style, and any text or notable elements. "
                    "Be thorough — this description will be used to generate a semantic embedding."
                )},
            ],
        }],
        max_tokens=500,
    )
    return response.choices[0].message.content


def embed_text(text: str) -> list[float]:
    response = openai_client.embeddings.create(model=EMBEDDING_MODEL, input=text)
    return response.data[0].embedding


def cosine_similarity(a: list[float], b: list[float]) -> float:
    dot = sum(x * y for x, y in zip(a, b))
    norm_a = math.sqrt(sum(x * x for x in a))
    norm_b = math.sqrt(sum(x * x for x in b))
    return dot / (norm_a * norm_b) if norm_a and norm_b else 0.0


# ── endpoints ─────────────────────────────────────────────────────────────────

@app.post("/embed/image", response_model=EmbedResponse)
async def embed_image(file: UploadFile = File(...)):
    if not file.content_type.startswith("image/"):
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
    result = await app.state.col.insert_one(doc)

    return EmbedResponse(
        id=str(result.inserted_id),
        vector=vector,
        description=description,
        dimensions=len(vector),
    )


@app.post("/embed/images/batch", response_model=list[EmbedResponse])
async def embed_images_batch(files: list[UploadFile] = File(...)):
    if len(files) > 10:
        raise HTTPException(400, "Max 10 images per batch")

    results = []
    for file in files:
        if not file.content_type.startswith("image/"):
            raise HTTPException(400, f"{file.filename} is not an image")

        data = await file.read()
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
        result = await app.state.col.insert_one(doc)
        results.append(EmbedResponse(
            id=str(result.inserted_id),
            vector=vector,
            description=description,
            dimensions=len(vector),
        ))

    return results


@app.post("/search/image", response_model=list[SearchResult])
async def search_by_image(file: UploadFile = File(...), top_k: int = 5):
    """Find the most similar stored images to the uploaded query image."""
    if not file.content_type.startswith("image/"):
        raise HTTPException(400, "File must be an image")

    data = await file.read()
    data_url = image_to_data_url(data, file.content_type)
    description = describe_image(data_url)
    query_vector = embed_text(description)

    docs = await app.state.col.find(
        {}, {"_id": 1, "filename": 1, "description": 1, "embedding": 1}
    ).to_list(length=None)

    scored = [
        SearchResult(
            id=str(doc["_id"]),
            filename=doc["filename"],
            description=doc["description"],
            score=cosine_similarity(query_vector, doc["embedding"]),
        )
        for doc in docs
    ]
    scored.sort(key=lambda x: x.score, reverse=True)
    return scored[:top_k]


@app.post("/search/text", response_model=list[SearchResult])
async def search_by_text(query: str, top_k: int = 5):
    """Find images whose embeddings are most similar to a text query."""
    query_vector = embed_text(query)

    docs = await app.state.col.find(
        {}, {"_id": 1, "filename": 1, "description": 1, "embedding": 1}
    ).to_list(length=None)

    scored = [
        SearchResult(
            id=str(doc["_id"]),
            filename=doc["filename"],
            description=doc["description"],
            score=cosine_similarity(query_vector, doc["embedding"]),
        )
        for doc in docs
    ]
    scored.sort(key=lambda x: x.score, reverse=True)
    return scored[:top_k]


@app.get("/images/{image_id}")
async def get_image(image_id: str):
    """Return the raw image bytes for a stored image."""
    try:
        oid = ObjectId(image_id)
    except Exception:
        raise HTTPException(400, "Invalid image id")

    doc = await app.state.col.find_one({"_id": oid}, {"image_data": 1, "content_type": 1})
    if not doc:
        raise HTTPException(404, "Image not found")

    return Response(content=bytes(doc["image_data"]), media_type=doc["content_type"])


@app.get("/images")
async def list_images():
    """List all stored images (metadata only, no binary data)."""
    docs = await app.state.col.find(
        {}, {"image_data": 0, "embedding": 0}
    ).to_list(length=None)
    return [
        {"id": str(d["_id"]), "filename": d["filename"], "description": d["description"], "created_at": d["created_at"]}
        for d in docs
    ]


@app.get("/health")
def health():
    return {"status": "ok"}
