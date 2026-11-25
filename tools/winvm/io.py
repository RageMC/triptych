import ctypes, sys, time, subprocess
pid=int(open(sys.argv[2]+'/pid').read()) if len(sys.argv)>2 else int(subprocess.check_output(['pgrep','-f','build/winvm']).split()[0])
lib=ctypes.CDLL('/usr/lib/libproc.dylib')
class RU(ctypes.Structure):
    _fields_=[('uuid',ctypes.c_uint8*16)]+[(n,ctypes.c_uint64) for n in ['user','system','pkg_idle_wkups','interrupt_wkups','pageins','wired','resident','phys_footprint','start_abstime','exit_abstime','child_user','child_system','child_pkg','child_int','child_pageins','child_elapsed','diskio_bytesread','diskio_byteswritten']]
def get():
    r=RU(); lib.proc_pid_rusage(pid,2,ctypes.byref(r)); return r.diskio_bytesread,r.diskio_byteswritten,r.user+r.system
n=int(sys.argv[1]) if len(sys.argv)>1 else 20
a=get(); time.sleep(n); b=get()
print('read %.2f MB/s  written %.2f MB/s  cpu %.0f%%'%((b[0]-a[0])/n/1e6,(b[1]-a[1])/n/1e6,(b[2]-a[2])/n/1e9*100*(125/3 if False else 1)))
