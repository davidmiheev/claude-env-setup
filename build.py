#!/usr/bin/env python3
"""Re-sync the shared blocks (parts/*.sh, delimited by '# >>> name' / '# <<< name') into every setup-*.sh."""
import glob, re, sys
parts = {}
for f in glob.glob('parts/*.sh'):
    t = open(f).read()
    m = re.match(r'# >>> (\S+)', t)
    parts[m.group(1)] = t.rstrip('\n') + '\n'
for script in glob.glob('setup-*.sh'):
    s = open(script).read(); orig = s
    for name, block in parts.items():
        pat = re.compile(r'# >>> ' + re.escape(name) + r'\b.*?# <<< ' + re.escape(name) + r'\n', re.S)
        if pat.search(s):
            s = pat.sub(lambda m: block, s)
    if s != orig:
        open(script, 'w').write(s); print('updated', script)
