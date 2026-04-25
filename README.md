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