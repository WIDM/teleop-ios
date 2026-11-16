#!/usr/bin/env python3
"""Relay between the phone and the teleop server, for development on a Mac.

    phone or test  ->  ws://<this Mac>:8765  ->  ws://127.0.0.1:8766 (the SSH tunnel to the simulator)

Every text message is forwarded unchanged. Unlike the server's own single-phone relay, this one takes
several clients at once, each with its own upstream connection, so a scripted test and a phone can both
be connected. Needs `pip install websockets`.
"""

import argparse
import asyncio

import websockets


async def serve_client(ws, upstream_url):
    peer = ws.remote_address[0] if ws.remote_address else "?"
    print(f"connect {peer}", flush=True)
    try:
        async with websockets.connect(upstream_url) as upstream:
            async def pump(source, sink):
                async for message in source:
                    await sink.send(message)

            done, pending = await asyncio.wait(
                [asyncio.create_task(pump(ws, upstream)), asyncio.create_task(pump(upstream, ws))],
                return_when=asyncio.FIRST_COMPLETED,
            )
            for task in pending:
                task.cancel()
    except Exception as error:  # say why, then drop the client; the app shows a lost link
        print(f"error {peer}: {error!r}", flush=True)
    finally:
        print(f"disconnect {peer}", flush=True)


async def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--listen", type=int, default=8765)
    parser.add_argument("--upstream", default="ws://127.0.0.1:8766")
    args = parser.parse_args()
    async with websockets.serve(lambda ws: serve_client(ws, args.upstream), "0.0.0.0", args.listen):
        print(f"relay on :{args.listen} -> {args.upstream}", flush=True)
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
