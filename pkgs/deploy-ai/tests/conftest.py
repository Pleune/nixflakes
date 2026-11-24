"""Put the tests dir on sys.path so modules can `from support import ...` from anywhere."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
