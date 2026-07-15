"""Pruebas de tunnel_crypto: roundtrip, integridad (Poly1305) y anti-replay.

    python test_crypto.py

Simula los dos extremos: un Tunnel("client") y un Tunnel("server") que se
cifran mutuamente, como los dos portátiles.
"""

from tunnel_crypto import (Tunnel, InvalidTag, ReplayError,
                           COUNTER_SIZE, TAG_SIZE, WINDOW_SIZE)


def test_roundtrip() -> None:
    client, server = Tunnel("client"), Tunnel("server")
    packet = bytes(range(60))
    datagram = client.seal(packet)
    assert server.open_(datagram) == packet, "servidor no recupera el paquete"
    # y en el otro sentido
    back = b"respuesta desde internet" * 2
    assert client.open_(server.seal(back)) == back, "cliente no recupera"
    overhead = len(datagram) - len(packet)
    assert overhead == COUNTER_SIZE + TAG_SIZE, overhead
    print(f"OK roundtrip bidireccional (overhead {overhead} B = "
          f"{COUNTER_SIZE} contador + {TAG_SIZE} tag)")


def test_direction_keys_differ() -> None:
    # Primer paquete de cada lado usa contador 0 -> mismo nonce. Con claves
    # por dirección los ciphertexts DEBEN diferir (si no, habría reuso).
    client, server = Tunnel("client"), Tunnel("server")
    p = b"contenido identico"
    assert client.seal(p)[COUNTER_SIZE:] != server.seal(p)[COUNTER_SIZE:]
    print("OK claves por dirección: mismo contador/plaintext -> ciphertext distinto")


def test_tamper_rejected() -> None:
    client, server = Tunnel("client"), Tunnel("server")
    datagram = bytearray(client.seal(b"paquete importante"))
    datagram[-1] ^= 0x01  # voltea un bit del tag
    try:
        server.open_(bytes(datagram))
    except InvalidTag:
        print("OK bit-flip rechazado por Poly1305 (InvalidTag)")
        return
    raise AssertionError("Poly1305 no detectó la alteración")


def test_replay_rejected() -> None:
    client, server = Tunnel("client"), Tunnel("server")
    datagram = client.seal(b"transferir 100 a la cuenta X")
    assert server.open_(datagram)                 # 1ra vez: aceptado
    try:
        server.open_(datagram)                    # reinyección: mismo contador
    except ReplayError:
        print("OK replay (reinyección del mismo datagrama) rechazado")
        return
    raise AssertionError("el replay no fue detectado")


def test_short_datagram_rejected() -> None:
    # Basura corta al puerto UDP: debe salir por InvalidTag, no reventar con
    # ValueError ("Nonce must be 12 bytes") y tumbar el servidor.
    server = Tunnel("server")
    for basura in (b"", b"abc", b"1234567"):
        try:
            server.open_(basura)
        except InvalidTag:
            continue
        raise AssertionError(f"datagrama corto {basura!r} no dio InvalidTag")
    print("OK datagrama corto rechazado como InvalidTag (no tumba el servidor)")


def test_out_of_order_ok_but_old_rejected() -> None:
    client, server = Tunnel("client"), Tunnel("server")
    # Genera varios datagramas (contadores 0..WINDOW_SIZE+2).
    grams = [client.seal(bytes([i % 250]) * 30) for i in range(WINDOW_SIZE + 3)]
    # Entrega el más nuevo primero: avanza la ventana de golpe.
    assert server.open_(grams[-1])
    # Uno reciente dentro de la ventana, fuera de orden: se acepta.
    assert server.open_(grams[-2]), "paquete reciente fuera de orden rechazado"
    # Uno muy viejo (contador 0), ya fuera de la ventana: se rechaza.
    try:
        server.open_(grams[0])
    except ReplayError:
        print("OK fuera de orden aceptado; demasiado viejo rechazado")
        return
    raise AssertionError("paquete viejo fuera de ventana no fue rechazado")


if __name__ == "__main__":
    test_roundtrip()
    test_direction_keys_differ()
    test_tamper_rejected()
    test_short_datagram_rejected()
    test_replay_rejected()
    test_out_of_order_ok_but_old_rejected()
    print("\nTodas las pruebas de cripto pasaron.")
