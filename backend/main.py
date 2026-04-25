"""Vercel FastAPI framework entrypoint.

Vercel's `fastapi` builder auto-detects this file (`main.py` at the
project root) and runs uvicorn against `main:app`. We just import the
existing FastAPI instance from `backend.py` so every route — `/api/build`,
`/code-edits`, `/api/plan`, `/api/modify`, `/api/modify-element`,
`/health`, etc. — is served from a single function on Fluid Compute.
"""

from backend import app  # noqa: F401  -- ASGI handler picked up by Vercel
