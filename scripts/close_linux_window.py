"""Send WM_DELETE_WINDOW to an X11 window owned by the specified test process."""
import ctypes as c
import sys
import time

pid = int(sys.argv[1])
x = c.CDLL("libX11.so.6")
x.XOpenDisplay.restype = c.c_void_p
x.XDefaultRootWindow.argtypes = [c.c_void_p]
x.XDefaultRootWindow.restype = c.c_ulong
x.XInternAtom.argtypes = [c.c_void_p, c.c_char_p, c.c_int]
x.XInternAtom.restype = c.c_ulong
x.XQueryTree.argtypes = [c.c_void_p, c.c_ulong, c.POINTER(c.c_ulong), c.POINTER(c.c_ulong), c.POINTER(c.POINTER(c.c_ulong)), c.POINTER(c.c_uint)]
x.XGetWindowProperty.argtypes = [c.c_void_p, c.c_ulong, c.c_ulong, c.c_long, c.c_long, c.c_int, c.c_ulong, c.POINTER(c.c_ulong), c.POINTER(c.c_int), c.POINTER(c.c_ulong), c.POINTER(c.c_ulong), c.POINTER(c.c_void_p)]
x.XFree.argtypes = [c.c_void_p]
x.XFlush.argtypes = [c.c_void_p]
x.XCloseDisplay.argtypes = [c.c_void_p]
display = x.XOpenDisplay(None)
if not display:
    raise SystemExit("No X11 display")
pid_atom = x.XInternAtom(display, b"_NET_WM_PID", 0)
protocols_atom = x.XInternAtom(display, b"WM_PROTOCOLS", 0)
delete_atom = x.XInternAtom(display, b"WM_DELETE_WINDOW", 0)
x.XGetGeometry.argtypes = [c.c_void_p, c.c_ulong, c.POINTER(c.c_ulong), c.POINTER(c.c_int), c.POINTER(c.c_int), c.POINTER(c.c_uint), c.POINTER(c.c_uint), c.POINTER(c.c_uint), c.POINTER(c.c_uint)]

def visible_size(window):
    root, left, top = c.c_ulong(), c.c_int(), c.c_int()
    width, height, border, depth = c.c_uint(), c.c_uint(), c.c_uint(), c.c_uint()
    return x.XGetGeometry(display, window, c.byref(root), c.byref(left), c.byref(top), c.byref(width), c.byref(height), c.byref(border), c.byref(depth)) and width.value >= 100 and height.value >= 100

def can_close(window):
    kind, fmt, count, remaining, data = c.c_ulong(), c.c_int(), c.c_ulong(), c.c_ulong(), c.c_void_p()
    x.XGetWindowProperty(display, window, protocols_atom, 0, 32, 0, 0, c.byref(kind), c.byref(fmt), c.byref(count), c.byref(remaining), c.byref(data))
    result = bool(data and fmt.value == 32 and delete_atom in c.cast(data, c.POINTER(c.c_ulong))[:count.value])
    if data:
        x.XFree(data)
    return result

def owner(window):
    kind, fmt, count, remaining, data = c.c_ulong(), c.c_int(), c.c_ulong(), c.c_ulong(), c.c_void_p()
    x.XGetWindowProperty(display, window, pid_atom, 0, 1, 0, 0, c.byref(kind), c.byref(fmt), c.byref(count), c.byref(remaining), c.byref(data))
    result = c.cast(data, c.POINTER(c.c_ulong))[0] if data and count.value else 0
    if data:
        x.XFree(data)
    return result

def find(window):
    if owner(window) == pid and can_close(window) and visible_size(window):
        return window
    root, parent, children, count = c.c_ulong(), c.c_ulong(), c.POINTER(c.c_ulong)(), c.c_uint()
    if not x.XQueryTree(display, window, c.byref(root), c.byref(parent), c.byref(children), c.byref(count)):
        return None
    result = None
    for index in range(count.value):
        result = find(children[index])
        if result:
            break
    if children:
        x.XFree(children)
    return result

class Message(c.Structure):
    _fields_ = [("type", c.c_int), ("serial", c.c_ulong), ("send_event", c.c_int),
                ("display", c.c_void_p), ("window", c.c_ulong), ("message_type", c.c_ulong),
                ("format", c.c_int), ("data", c.c_long * 5), ("padding", c.c_long * 12)]

deadline = time.monotonic() + 45
window = None
while time.monotonic() < deadline and not window:
    window = find(x.XDefaultRootWindow(display))
    if not window:
        time.sleep(0.1)
if not window:
    raise SystemExit(f"No window owned by PID {pid}")
event = Message(type=33, send_event=1, display=display, window=window,
                message_type=x.XInternAtom(display, b"WM_PROTOCOLS", 0), format=32)
event.data[0] = delete_atom
print(f"Closing test window {window:#x} owned by PID {pid}")
x.XSendEvent.argtypes = [c.c_void_p, c.c_ulong, c.c_int, c.c_long, c.POINTER(Message)]
if not x.XSendEvent(display, window, 0, 0, c.byref(event)):
    raise SystemExit("Window close event failed")
x.XFlush(display)
x.XCloseDisplay(display)
