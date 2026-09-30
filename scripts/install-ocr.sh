#!/usr/bin/env bash
# Installs local OCR models outside the repository. Data pinned by revision and SHA-256.
set -euo pipefail
if [[ ! -x /opt/homebrew/bin/tesseract && ! -x /usr/local/bin/tesseract ]]; then
  brew install tesseract
fi
python3 - <<'PY'
import hashlib
import os
from pathlib import Path
import tempfile
import urllib.request

revision = '87416418657359cb625c412a48b6e1d6d41c29bd'
checksums = {
    'heb': '11f9e43ab227f786352a50f75c94c2e9906f1baba86d93276da19da7ce0904db',
    'eng': '7d4322bd2a7749724879683fc3912cb542f19906c83bcc1a52132556427170b2',
}
folder = Path.home() / 'Library/Application Support/Taplyne/OCR'
folder.mkdir(parents=True, exist_ok=True)
for language, checksum in checksums.items():
    target = folder / f'{language}.traineddata'
    if target.is_file() and hashlib.sha256(target.read_bytes()).hexdigest() == checksum:
        continue
    url = f'https://raw.githubusercontent.com/tesseract-ocr/tessdata_fast/{revision}/{language}.traineddata'
    with urllib.request.urlopen(url, timeout=30) as response:
        data = response.read(10_000_001)
    if hashlib.sha256(data).hexdigest() != checksum:
        raise SystemExit(f'OCR checksum mismatch for {language}; no model was installed.')
    fd, temporary = tempfile.mkstemp(dir=folder, prefix='.model-')
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
        os.replace(temporary, target)
    finally:
        Path(temporary).unlink(missing_ok=True)
print('English and Hebrew OCR models are installed locally.')
PY
