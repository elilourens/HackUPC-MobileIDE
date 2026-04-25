"""Vercel Fluid Compute entrypoint.

Vercel auto-detects ASGI apps exported as `app` from a Python file in
`api/`. We just import the FastAPI instance from `backend.py` so the whole
existing route surface (`/api/build`, `/code-edits`, `/api/plan`,
`/api/modify`, `/api/modify-element`, `/health`, etc.) is served from a
single function. `vercel.json` rewrites every URL to this entrypoint.
"""

from backend import app  # noqa: F401  -- ASGI handler picked up by Vercel
