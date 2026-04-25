# HackUPC-MobileIDE

## AI Ghost Pair Programmer

### Setup

```bash
cd backend
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
uvicorn backend:app --reload
```

Add your real `ELEVENLABS_API_KEY` in `.env`.

### Test Voice

```bash
PYTHONPATH=. python3 tests/test_elevenlabs_direct.py
```

### Test Ghost

```bash
PYTHONPATH=. python3 tests/test_ghost_chat.py
```

### Testing Ghost with a file

Examples:

```bash
PYTHONPATH=. python3 tests/run_file_test.py sample.py
PYTHONPATH=. python3 tests/run_file_test.py sample.py --voice
PYTHONPATH=. python3 tests/run_file_test.py sample.py --question "Find security issues"
```

### Ghost Conversation Mode

Flow:
1. Ask Ghost about code.
2. Modify code.
3. Ask a spoken or text follow-up.
4. Ghost uses conversation context and code changes to respond.

Run conversation mode test:

```bash
PYTHONPATH=. python3 tests/test_conversation_mode.py --voice
```

## Spatial Scenes

The AETHER AR workspace supports switchable scene ambience.

- EXR assets live in `Aether/Aether/Resources/EnvironmentMaps/`
  - `cambridge_4k.exr`
  - `canary_wharf_4k.exr`
  - `pretoria_gardens_4k.exr`
- Scene picker is in the AR Workspace HUD via the **Scene** button.
- Available scenes:
  - Cambridge
  - Canary Wharf
  - Pretoria Gardens
  - Focus Mode
- **Real World** returns the workspace to normal camera passthrough AR.
- The app attempts EXR loading for environment ambience and logs success/failure.
  If EXR usage is unavailable at runtime, it automatically falls back to procedural scene visuals.