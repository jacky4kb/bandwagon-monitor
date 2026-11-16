#!/bin/zsh
# Update only this application and its own widget processes.
set -euo pipefail
ROOT="${0:A:h:h}"
SOURCE="${1:-$ROOT/dist/搬瓦工监控.app}"
TARGET="${2:-/Applications/搬瓦工监控.app}"
python3 - "$SOURCE" "$TARGET" <<'PY'
import ctypes
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys

source, target = (Path(arg).resolve() for arg in sys.argv[1:3])
if source == target:
    raise SystemExit('Build source and install target must be different.')
info = plistlib.loads((source/'Contents/Info.plist').read_bytes())
bundle_id = 'local.bandwagon.monitor'
if info.get('CFBundleIdentifier') != bundle_id or info.get('PreviewOnly'):
    raise SystemExit('Install a signed production build, not a preview build.')
subprocess.run(['codesign','--verify','--deep','--strict',str(source)],check=True)
if target.exists():
    previous = plistlib.loads((target/'Contents/Info.plist').read_bytes())
    if previous.get('CFBundleIdentifier') != bundle_id:
        raise SystemExit('A different application already occupies the target.')

# Use actual executable paths, not process names or argv[0].
# The login agent can run with a short argv[0]; several apps may share a name.
executables = {
    str(target/'Contents/MacOS/BandwagonMonitor'),
    str(target/'Contents/PlugIns/BandwagonWidgets.appex/Contents/MacOS/BandwagonWidgets'),
}
libproc = ctypes.CDLL('/usr/lib/libproc.dylib')
processes = []
for value in subprocess.check_output(['ps','-axo','pid='],text=True).split():
    pid = int(value)
    buffer = ctypes.create_string_buffer(4096)
    if libproc.proc_pidpath(pid,buffer,4096) > 0 and buffer.value.decode() in executables:
        processes.append(pid)
for pid in processes:
    try:
        os.kill(pid,signal.SIGTERM)
    except ProcessLookupError:
        pass
# Never overwrite an executable while its old process is still active.
import time
for attempt in range(30):
    alive = []
    for pid in processes:
        try:
            os.kill(pid,0)
            alive.append(pid)
        except ProcessLookupError:
            pass
    if not alive:
        break
    time.sleep(0.1)
else:
    raise SystemExit('Application has not stopped. Close it and retry; nothing was overwritten.')

extension = target/'Contents/PlugIns/BandwagonWidgets.appex'
if extension.exists():
    subprocess.run(['pluginkit','-r',str(extension)],check=False)
subprocess.run(['ditto',str(source),str(target)],check=True)
subprocess.run(['codesign','--verify','--deep','--strict',str(target)],check=True)
lsregister = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
subprocess.run([lsregister,'-f',str(target)],check=True)
subprocess.run(['pluginkit','-a',str(extension)],check=True)
service = f'gui/{os.getuid()}/{bundle_id}.autostart'
registered = subprocess.run(['launchctl','print',service],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode == 0
if registered:
    subprocess.run(['launchctl','kickstart',service],check=True)
else:
    subprocess.run(['open',str(target)],check=True)
print('Installed and registered the current app and widget version.')
PY
