#!/usr/bin/env python3
"""Remove PNG text/EXIF chunks without changing pixels or recompressing image data."""
from pathlib import Path
import struct
import sys
for folder in sys.argv[1:]:
    for path in Path(folder).glob('*.png'):
        raw = path.read_bytes()
        assert raw[:8] == b'\x89PNG\r\n\x1a\n', path
        out = bytearray(raw[:8]); offset = 8
        while offset + 12 <= len(raw):
            size = struct.unpack('>I', raw[offset:offset+4])[0]
            end = offset + 12 + size
            assert end <= len(raw), path
            if raw[offset+4:offset+8] not in {b'tEXt',b'iTXt',b'zTXt',b'eXIf'}:
                out.extend(raw[offset:end])
            offset = end
        path.write_bytes(out)
