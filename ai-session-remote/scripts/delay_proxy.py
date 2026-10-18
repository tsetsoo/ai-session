#!/usr/bin/env python3
"""TCP proxy that adds fixed one-way delay in each direction (for RTT ≈ 2 * delay)."""

from __future__ import annotations

import argparse
import asyncio
import sys


async def pipe(reader: asyncio.StreamReader, writer: asyncio.StreamWriter, delay: float) -> None:
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            await asyncio.sleep(delay)
            writer.write(data)
            await writer.drain()
    except (asyncio.CancelledError, ConnectionResetError, BrokenPipeError):
        pass
    finally:
        try:
            writer.close()
            await writer.wait_closed()
        except Exception:
            pass


async def handle(
    client_reader: asyncio.StreamReader,
    client_writer: asyncio.StreamWriter,
    upstream_host: str,
    upstream_port: int,
    delay: float,
) -> None:
    try:
        remote_reader, remote_writer = await asyncio.open_connection(upstream_host, upstream_port)
    except OSError as exc:
        print(f"upstream connect failed: {exc}", file=sys.stderr)
        client_writer.close()
        return

    t1 = asyncio.create_task(pipe(client_reader, remote_writer, delay))
    t2 = asyncio.create_task(pipe(remote_reader, client_writer, delay))
    await asyncio.wait({t1, t2}, return_when=asyncio.FIRST_COMPLETED)
    t1.cancel()
    t2.cancel()


async def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen", default="127.0.0.1:18022")
    parser.add_argument("--upstream", default="100.118.255.23:22")
    parser.add_argument("--delay-ms", type=float, default=75.0, help="one-way delay; RTT ≈ 2x")
    args = parser.parse_args()

    listen_host, listen_port = args.listen.rsplit(":", 1)
    up_host, up_port = args.upstream.rsplit(":", 1)
    delay = args.delay_ms / 1000.0

    server = await asyncio.start_server(
        lambda r, w: handle(r, w, up_host, int(up_port), delay),
        listen_host,
        int(listen_port),
    )
    print(f"delay proxy on {args.listen} -> {args.upstream} (+{args.delay_ms:.0f}ms each way)", flush=True)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
