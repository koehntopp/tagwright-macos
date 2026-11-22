"""Writes Resources/unidecode.bin for Naming.clean (python-slugify's transliteration, from the web app's own packages).

Format, raw DEFLATE: records of u32 big-endian code point, u8 length, ASCII bytes (unidecode of that character,
only where it is not empty), then u32 0xFFFFFFFF, then the HTML entity names as "name\\tcodepoint\\n" lines.
Run with the web app's interpreter: ../tagwright/.venv/bin/python scripts/gen-unidecode.py
"""

import struct
import zlib
from html.entities import name2codepoint
from pathlib import Path

from unidecode import unidecode

out = bytearray()
for cp in range(0x80, 0x30000):
	if 0xD800 <= cp <= 0xDFFF:
		continue
	s = unidecode(chr(cp))
	if s:
		b = s.encode('ascii')
		out += struct.pack('>IB', cp, len(b)) + b
out += struct.pack('>I', 0xFFFFFFFF)
out += ''.join(f'{n}\t{c}\n' for n, c in sorted(name2codepoint.items())).encode('ascii')
c = zlib.compressobj(9, zlib.DEFLATED, -15)
data = c.compress(bytes(out)) + c.flush()
dst = Path(__file__).resolve().parents[1] / 'Resources' / 'unidecode.bin'
dst.write_bytes(data)
print(dst, len(out), '->', len(data))
