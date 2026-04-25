import json
import re
from pathlib import Path
from typing import Any, Optional


def _extension_hint(filename: Optional[str]) -> Optional[str]:
    if not filename:
        return None
    extension = Path(filename).suffix.lower()
    mapping = {
        ".py": "python",
        ".js": "javascript",
        ".mjs": "javascript",
        ".cjs": "javascript",
        ".ts": "typescript",
        ".tsx": "react",
        ".jsx": "react",
        ".html": "html",
        ".htm": "html",
        ".css": "css",
        ".json": "json",
        ".swift": "swift",
    }
    return mapping.get(extension)


def _is_valid_json(code: str) -> bool:
    try:
        json.loads(code)
        return True
    except Exception:
        return False


def detect_language(code: str, filename: Optional[str] = None) -> str:
    text = code or ""
    hint = _extension_hint(filename)
    lowered = text.lower()

    # Strong syntax-first detection.
    react_markers = [
        "export default function",
        "classname=",
        "usestate(",
        "useeffect(",
    ]
    if any(marker in lowered for marker in react_markers) or re.search(r"<[A-Z][A-Za-z0-9]*", text):
        return "react"

    if "import swiftui" in lowered or re.search(r"struct\s+\w+\s*:\s*View", text) or "var body: some view" in lowered:
        return "swift"

    if "<!doctype html>" in lowered or re.search(r"<html\b", lowered) or re.search(r"<div\b", lowered):
        return "html"

    css_hits = [
        bool(re.search(r"@[a-z]+\s*[^{]*\{", text)),
        bool(re.search(r"[.#]?[a-zA-Z][\w\-]*\s*\{[^}]*:[^}]*;", text)),
    ]
    if any(css_hits):
        return "css"

    ts_hits = [
        "interface " in text,
        re.search(r"\btype\s+\w+\s*=", text) is not None,
        re.search(r":\s*(string|number|boolean|unknown|any)\b", text) is not None,
        re.search(r"<[A-Za-z][A-Za-z0-9_,\s]*>", text) is not None and "function" in text,
    ]
    if any(ts_hits):
        return "typescript"

    js_hits = [
        "function " in text,
        "console.log" in text,
        "=>" in text,
        re.search(r"\b(const|let|var)\s+\w+", text) is not None,
    ]
    if any(js_hits):
        return "javascript"

    py_hits = [
        re.search(r"^\s*def\s+\w+\(", text, flags=re.MULTILINE) is not None,
        re.search(r"^\s*import\s+\w+", text, flags=re.MULTILINE) is not None,
        re.search(r"^\s*from\s+\w+(\.\w+)*\s+import\s+", text, flags=re.MULTILINE) is not None,
        re.search(r"^\s*class\s+\w+.*:", text, flags=re.MULTILINE) is not None,
        re.search(r":\s*(#.*)?\n\s{2,}\S", text) is not None,
    ]
    if any(py_hits):
        return "python"

    if _is_valid_json(text):
        return "json"

    if hint:
        return hint
    return "unknown"


def _detect_suspicious_patterns(code: str) -> list[str]:
    patterns: list[str] = []

    if re.search(r"function\s+add\s*\(\s*([a-zA-Z_]\w*)\s*,\s*([a-zA-Z_]\w*)\s*\)\s*\{\s*return\s+\1\s*-\s*\2\s*;?\s*\}", code):
        patterns.append("add() appears to subtract values")

    if re.search(r"^\s*except\s*:\s*\n\s*pass\b", code, flags=re.MULTILINE):
        patterns.append("empty except/pass block")
    elif re.search(r"^\s*except\s*:\s*$", code, flags=re.MULTILINE):
        patterns.append("bare except block")
    elif re.search(r"^\s*except\s+Exception\s*:\s*\n\s*pass\b", code, flags=re.MULTILINE):
        patterns.append("exception swallowed with pass")

    console_count = len(re.findall(r"console\.log\(", code))
    if console_count >= 3:
        patterns.append("console.log spam detected")

    if re.search(r"(sk_[a-zA-Z0-9]{8,}|api_key\s*=|token\s*=|secret\s*=)", code, flags=re.IGNORECASE):
        patterns.append("possible hardcoded secret")

    if re.search(r"\b(TODO|FIXME)\b", code, flags=re.IGNORECASE):
        patterns.append("unfinished TODO/FIXME markers")

    if re.search(r"^\s*#\s*(if|for|while|return|print|console\.log|def|class)\b", code, flags=re.MULTILINE) or re.search(
        r"^\s*//\s*(if|for|while|return|console\.log|function|const|let|var)\b", code, flags=re.MULTILINE
    ):
        patterns.append("commented dead code")

    return patterns


def extract_basic_context(code: str, filename: Optional[str] = None) -> dict[str, Any]:
    function_count = len(
        re.findall(
            r"(^\s*def\s+\w+\()|(^\s*function\s+\w+\()|(^\s*const\s+\w+\s*=\s*\()|(^\s*func\s+\w+\()",
            code,
            flags=re.MULTILINE,
        )
    )
    class_count = len(
        re.findall(r"(^\s*class\s+\w+)|(^\s*interface\s+\w+)|(^\s*struct\s+\w+\s*:)", code, flags=re.MULTILINE)
    )
    todo_count = len(re.findall(r"\b(TODO|FIXME)\b", code, flags=re.IGNORECASE))
    has_console_logs = "console.log(" in code
    suspicious_patterns = _detect_suspicious_patterns(code)

    return {
        "line_count": len(code.splitlines()) if code else 0,
        "function_count": function_count,
        "class_count": class_count,
        "todo_count": todo_count,
        "has_console_logs": has_console_logs,
        "has_possible_secret": any("secret" in item for item in suspicious_patterns),
        "suspicious_patterns": suspicious_patterns,
        "filename_hint": filename,
    }


def summarize_code_shape(code: str) -> str:
    language = detect_language(code)
    line_count = len(code.splitlines())

    if language == "react":
        return "React component file"
    if language == "swift":
        return "SwiftUI view"
    if language == "json":
        return "JSON config"
    if language in {"python", "typescript", "javascript"} and line_count <= 25:
        return "Small utility function"
    if language in {"python", "typescript", "javascript"} and line_count > 120:
        return "Large backend module"
    if line_count <= 10:
        return "Small code snippet"
    return "General source file"
