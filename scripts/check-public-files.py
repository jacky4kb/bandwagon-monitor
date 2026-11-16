#!/usr/bin/env python3
"""Check repository sources and screenshot metadata without accessing user data."""
from pathlib import Path
import re
import struct
import sys
root = Path(__file__).resolve().parents[1]
issues = []
count = 0
skip = {'.git', 'dist', '.build', '__pycache__'}
for path in root.rglob('*'):
    rel = path.relative_to(root)
    if any(part in skip for part in rel.parts) or not path.is_file():
        continue
    count += 1
    if any(part.endswith(('.app','.appex')) for part in rel.parts):
        issues.append(f'{rel}: application bundle must not be included in public source')
    if path.suffix not in {'.swift','.sh','.py','.md','.txt','.png','.icns'} and path.name not in {'.gitignore','LICENSE'}:
        issues.append(f'{rel}: file type outside public source allowlist')
    if path.suffix in {'.p12', '.pfx', '.key', '.pem', '.cer', '.mobileprovision', '.provisionprofile', '.entitlements', '.log', '.ips'} or path.name.startswith('.env') or path.name == 'widget-snapshot.json':
        issues.append(f'{rel}: private/generated file type')
    if path.suffix in {'.swift', '.sh', '.py', '.md', '.txt'}:
        text = path.read_text()
        checks = {
            'personal absolute path': r'/(?:Users|home)/[a-zA-Z0-9_-]+/',
            'hardcoded signing fingerprint': r'(?i)SIGN_IDENTITY[^\n]*[0-9a-f]{40}',
            'hardcoded team group': r'\b[A-Z0-9]{10}\.local\.bandwagon\.monitor',
            'private key': r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
            'assigned API key': r'(?i)(?:api_key|apiKey)\s*[:=]\s*[\"\x27][a-zA-Z0-9_-]{24,}',
        }
        for label, pattern in checks.items():
            if re.search(pattern, text): issues.append(f'{rel}: {label}')
    if path.suffix == '.png':
        data = path.read_bytes()
        if data[:8] != b'\x89PNG\r\n\x1a\n':
            issues.append(f'{rel}: invalid PNG'); continue
        offset = 8
        while offset + 12 <= len(data):
            size = struct.unpack('>I',data[offset:offset+4])[0]
            kind = data[offset+4:offset+8]
            if kind in {b'tEXt', b'iTXt', b'zTXt', b'eXIf'}:
                issues.append(f'{rel}: embedded text/EXIF metadata')
            offset += size + 12
print(f'Checked {count} public files.')
if issues:
    print('\n'.join(issues)); sys.exit(1)
print('PASS: no flagged private files, personal paths, signing defaults or screenshot text metadata.')
