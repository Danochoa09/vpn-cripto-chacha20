"""Envoltorio ctypes para Wintun: una interfaz TUN en Windows.

Wintun es el driver TUN en espacio de usuario de WireGuard. Expone un
adaptador de red virtual; lo que se "lee" son paquetes IP completos que el
sistema quiere enviar, y lo que se "escribe" se inyecta como si llegara de
la red.

Requiere:
  - wintun.dll (descargar de https://www.wintun.net/, misma arquitectura
    que el intérprete de Python; normalmente amd64).
  - Ejecutar Python como Administrador (crear un adaptador necesita privilegios).

Solo Windows.
"""

import ctypes
import os
from ctypes import wintypes

# Capacidad del anillo de recepción: potencia de 2 entre 128 KiB y 64 MiB.
_RING_CAPACITY = 0x400000  # 4 MiB
_ERROR_NO_MORE_ITEMS = 259
_WAIT_OBJECT_0 = 0

_wintun = None


def _load(dll_path: str = "wintun.dll"):
    global _wintun
    if _wintun is not None:
        return _wintun

    # Python 3.8+ ya no busca DLLs en el directorio actual con nombre suelto.
    # Si el nombre no es una ruta, lo resolvemos junto a este archivo.
    if not os.path.isabs(dll_path) and os.sep not in dll_path:
        here = os.path.join(os.path.dirname(os.path.abspath(__file__)), dll_path)
        if os.path.exists(here):
            dll_path = here

    # use_last_error=True para que ctypes.get_last_error() devuelva el código
    # de error real de Win32 tras cada llamada (si no, siempre daría 0).
    dll = ctypes.WinDLL(dll_path, use_last_error=True)

    dll.WintunCreateAdapter.restype = wintypes.HANDLE
    dll.WintunCreateAdapter.argtypes = [wintypes.LPCWSTR, wintypes.LPCWSTR,
                                        ctypes.c_void_p]
    dll.WintunCloseAdapter.argtypes = [wintypes.HANDLE]

    dll.WintunStartSession.restype = wintypes.HANDLE
    dll.WintunStartSession.argtypes = [wintypes.HANDLE, wintypes.DWORD]
    dll.WintunEndSession.argtypes = [wintypes.HANDLE]

    dll.WintunGetReadWaitEvent.restype = wintypes.HANDLE
    dll.WintunGetReadWaitEvent.argtypes = [wintypes.HANDLE]

    dll.WintunReceivePacket.restype = ctypes.POINTER(ctypes.c_ubyte)
    dll.WintunReceivePacket.argtypes = [wintypes.HANDLE,
                                        ctypes.POINTER(wintypes.DWORD)]
    dll.WintunReleaseReceivePacket.argtypes = [wintypes.HANDLE,
                                               ctypes.POINTER(ctypes.c_ubyte)]

    dll.WintunAllocateSendPacket.restype = ctypes.POINTER(ctypes.c_ubyte)
    dll.WintunAllocateSendPacket.argtypes = [wintypes.HANDLE, wintypes.DWORD]
    dll.WintunSendPacket.argtypes = [wintypes.HANDLE,
                                     ctypes.POINTER(ctypes.c_ubyte)]

    dll.WintunGetAdapterLUID.argtypes = [wintypes.HANDLE, ctypes.c_void_p]

    # WaitForSingleObject de kernel32, con firma explícita.
    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    k32.WaitForSingleObject.restype = wintypes.DWORD
    k32.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]

    dll._wait = k32.WaitForSingleObject
    _wintun = dll
    return dll


class TunAdapter:
    """Adaptador Wintun. Usar como context manager."""

    def __init__(self, name: str = "CriptoVPN", tunnel_type: str = "CriptoVPN",
                 dll_path: str = "wintun.dll"):
        self._dll = _load(dll_path)
        self._name = name
        self._tunnel_type = tunnel_type
        self._adapter = None
        self._session = None

    def __enter__(self) -> "TunAdapter":
        self._adapter = self._dll.WintunCreateAdapter(self._name,
                                                      self._tunnel_type, None)
        if not self._adapter:
            raise OSError(f"WintunCreateAdapter falló (¿Administrador?): "
                          f"{ctypes.get_last_error()}")
        self._session = self._dll.WintunStartSession(self._adapter,
                                                     _RING_CAPACITY)
        if not self._session:
            self._dll.WintunCloseAdapter(self._adapter)
            raise OSError(f"WintunStartSession falló: "
                          f"{ctypes.get_last_error()}")
        self._read_event = self._dll.WintunGetReadWaitEvent(self._session)
        return self

    def __exit__(self, *exc) -> None:
        if self._session:
            self._dll.WintunEndSession(self._session)
        if self._adapter:
            self._dll.WintunCloseAdapter(self._adapter)

    def luid(self) -> int:
        """LUID del adaptador (para configurar IP/rutas por API si se quiere)."""
        buf = ctypes.c_ulonglong(0)
        self._dll.WintunGetAdapterLUID(self._adapter, ctypes.byref(buf))
        return buf.value

    def read(self, timeout_ms: int = 0xFFFFFFFF) -> bytes | None:
        """Devuelve el siguiente paquete IP saliente, o None si hubo timeout."""
        size = wintypes.DWORD(0)
        while True:
            ptr = self._dll.WintunReceivePacket(self._session,
                                                ctypes.byref(size))
            if ptr:
                data = bytes(ctypes.cast(
                    ptr, ctypes.POINTER(ctypes.c_ubyte * size.value)).contents)
                self._dll.WintunReleaseReceivePacket(self._session, ptr)
                return data
            if ctypes.get_last_error() != _ERROR_NO_MORE_ITEMS:
                raise OSError(f"WintunReceivePacket falló: "
                              f"{ctypes.get_last_error()}")
            # Anillo vacío: esperar a que llegue algo.
            rc = self._dll._wait(self._read_event, timeout_ms)
            if rc != _WAIT_OBJECT_0:
                return None

    def write(self, packet: bytes) -> None:
        """Inyecta un paquete IP en la interfaz."""
        ptr = self._dll.WintunAllocateSendPacket(self._session, len(packet))
        if not ptr:
            raise OSError(f"WintunAllocateSendPacket falló: "
                          f"{ctypes.get_last_error()}")
        ctypes.memmove(ptr, packet, len(packet))
        self._dll.WintunSendPacket(self._session, ptr)


if __name__ == "__main__":
    # Prueba mínima: crear el adaptador y leer un paquete. Necesita Admin.
    print("Creando adaptador Wintun 'CriptoVPN' ...")
    with TunAdapter() as tun:
        print(f"OK. LUID = {tun.luid():#x}")
        print("Configura la IP en otra terminal y haz ping para ver tráfico.")
        pkt = tun.read(timeout_ms=15000)
        if pkt:
            print(f"Paquete leído: {len(pkt)} bytes, primeros: {pkt[:20].hex()}")
        else:
            print("Sin tráfico en 15 s (normal si no configuraste IP).")
