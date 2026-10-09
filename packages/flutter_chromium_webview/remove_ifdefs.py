import os, glob, re

files = [
    'macos/Host/HostBrowserClient.mm',
    'macos/Host/JavaScriptRequests.mm',
    'macos/Host/IpcConnection.mm',
    'macos/Classes/ChromiumBackend.mm',
    'macos/Classes/ChromiumTexture.mm',
]

for f in files:
    with open(f, 'r') as file:
        content = file.read()
    
    content = re.sub(r'#ifdef DEBUG\n(.*?g_counters.*?)\n#endif', r'\1', content, flags=re.DOTALL)
    
    with open(f, 'w') as file:
        file.write(content)
