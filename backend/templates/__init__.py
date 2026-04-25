"""Curated React+Tailwind website templates.

Each template module exports:
  - TEMPLATE_ID: short stable id ("saas_landing", "ai_tool", ...)
  - DESCRIPTION: one-line blurb used by the router LLM to pick a template
  - SPEC_SCHEMA_HINT: JSON-schema-like prose the router shows the model so it
    knows what slots to fill
  - render(spec: dict) -> dict[str, str]: produces a full multi-file project
    keyed by repo-relative path. The render fn is responsible for sane
    defaults if any slot is missing — never crash on partial spec.

The router endpoint (`/api/build`) asks the model to pick a TEMPLATE_ID +
emit a spec dict, then we render it. Falls back to freeform LLM codegen if
no template fits. This keeps the demo fast (~3s populate vs ~60s freeform)
and consistently high-quality (curated layouts vs coin-flip JSX).
"""

from . import saas_landing, ai_tool, portfolio, ecommerce, dashboard, app_waitlist, blog, restaurant

REGISTRY = {
    saas_landing.TEMPLATE_ID: saas_landing,
    ai_tool.TEMPLATE_ID: ai_tool,
    portfolio.TEMPLATE_ID: portfolio,
    ecommerce.TEMPLATE_ID: ecommerce,
    dashboard.TEMPLATE_ID: dashboard,
    app_waitlist.TEMPLATE_ID: app_waitlist,
    blog.TEMPLATE_ID: blog,
    restaurant.TEMPLATE_ID: restaurant,
}


def list_for_router() -> list[dict]:
    """Compact template manifest for the router system prompt: id +
    description + a hint of the spec shape. Kept tight on tokens because
    we ship the whole list to GPT on every build call."""
    return [
        {
            "id": mod.TEMPLATE_ID,
            "description": mod.DESCRIPTION,
            "spec": mod.SPEC_SCHEMA_HINT,
        }
        for mod in REGISTRY.values()
    ]


def get(template_id: str):
    """Look up a template module by id. Returns None if unknown so the
    caller can fall back to freeform codegen."""
    return REGISTRY.get(template_id)
