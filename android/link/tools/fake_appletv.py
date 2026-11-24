#!/usr/bin/env python3
"""Pretends to be Kumori on an Apple TV, so Kumori Link can be tested from a computer.

    python3 fake_appletv.py 192.168.1.20

Prints every controller state the box sends and answers its pings.
"""
import socket, struct, sys, time

PORT = 47820
HELLO, INFO, STATE, PING, PONG, BYE = 1, 2, 3, 4, 5, 6

def main():
    host = sys.argv[1]
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(0.2)
    name = b"fake Apple TV"
    session = int(time.time()) & 0xFFFFFFFF
    last_hello = 0.0
    last = {}
    while True:
        if time.time() - last_hello > 1:
            s.sendto(b"KL\x01" + bytes([HELLO]) + struct.pack("<IH", session, len(name)) + name, (host, PORT))
            last_hello = time.time()
        try:
            data, addr = s.recvfrom(512)
        except socket.timeout:
            continue
        if data[:2] != b"KL":
            continue
        kind, body = data[3], data[4:]
        if kind == INFO:
            print("INFO", body)
        elif kind == PING:
            s.sendto(b"KL\x01" + bytes([PONG]) + body, addr)
        elif kind == STATE:
            seq, t, slot, mask, flags, _, buttons, lt, rt, lx, ly, rx, ry = struct.unpack("<IQBBBBHBBhhhh", body[:28])
            now = (slot, mask, flags, buttons, lt, rt, lx, ly, rx, ry)
            if last.get(slot) != now:
                last[slot] = now
                print(f"p{slot+1} seq {seq} mask {mask:04b} flags {flags} buttons {buttons:04x} LT {lt:3} RT {rt:3} L({lx:6},{ly:6}) R({rx:6},{ry:6})")

if __name__ == "__main__":
    main()
