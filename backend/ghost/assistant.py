from typing import Any

from ghost.code_context import detect_language, extract_basic_context, summarize_code_shape
from ghost.schemas import GhostChatRequest


BUG_KEYWORDS = ("what is wrong", "bug", "error", "fix", "issue", "broken")


def _build_action_items(context: dict[str, Any], language: str) -> list[str]:
    actions: list[str] = []
    suspicious = context["suspicious_patterns"]

    if any("add() appears to subtract values" in item for item in suspicious):
        actions.append("Change a-b to a+b")
        actions.append("Add a unit test for add(2,3)=5")

    if any("possible hardcoded secret" in item for item in suspicious):
        actions.append("Move keys/tokens to environment variables")
        actions.append("Rotate any exposed credentials")

    if context["todo_count"] > 0:
        actions.append("Resolve TODO/FIXME items before release")

    if context["has_console_logs"] and language in {"javascript", "typescript", "react"}:
        actions.append("Reduce console.log usage and add structured logging")

    if not actions:
        actions.append("Add focused tests around the most critical logic paths")
    return actions[:4]


def generate_ghost_reply(request: GhostChatRequest) -> dict[str, Any]:
    code = request.code
    question = request.question.strip()
    lowered_question = question.lower()

    language = detect_language(code, request.filename)
    context = extract_basic_context(code, request.filename)
    code_shape = summarize_code_shape(code)
    suspicious = context["suspicious_patterns"]
    actions = _build_action_items(context, language)

    bug_mode = any(keyword in lowered_question for keyword in BUG_KEYWORDS)
    summary = f"{code_shape}. {context['line_count']} lines inspected."
    reply = (
        "This looks like a general code snippet. I can walk through logic, structure, and safety concerns if you want."
    )

    if any("add() appears to subtract values" in item for item in suspicious):
        reply = (
            "Warning. I found a likely logic bug. The function is named add, but it returns a - b. "
            "Change it to return a + b, then add a test for add(2,3)=5."
        )
        summary = "Likely arithmetic logic bug."
    elif language == "swift":
        reply = (
            "This is Swift using SwiftUI. It defines a View and renders UI from the body property. "
            "The structure looks valid; next step is checking state and preview behavior."
        )
        summary = "SwiftUI view structure detected."
    elif language == "react":
        reply = (
            "This appears to be a React component. I see component-style structure and hook or JSX indicators. "
            "Check hook dependencies and prop typing to avoid subtle UI bugs."
        )
        summary = "React component logic detected."
    elif bug_mode and suspicious:
        reply = (
            "Warning. I found likely issues: "
            + "; ".join(suspicious[:3])
            + ". Start by fixing these and adding quick regression tests."
        )
        summary = "Potential bugs and code smells found."
    elif bug_mode:
        reply = (
            "I do not see a single obvious runtime bug, but I would validate edge cases, inputs, and expected outputs. "
            "A targeted unit test pass should reveal hidden issues."
        )
        summary = "No obvious single bug; testing recommended."
    else:
        reply = (
            f"This looks like {code_shape.lower()}. "
            "Overall structure is understandable, but quality can improve with stricter tests and cleanup."
        )

    if any("possible hardcoded secret" in item for item in suspicious):
        reply += " Security note: possible hardcoded secret detected. Move secrets to environment variables."
        summary = "Potential secret exposure detected."

    if context["todo_count"] > 0:
        reply += " I also found TODO/FIXME markers that indicate unfinished work."

    return {
        "detected_language": language,
        "reply": reply,
        "summary": summary,
        "suggested_actions": actions,
    }
