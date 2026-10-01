#!/usr/bin/env python3
"""Launch an installed WDA XCTest host in the background through RemoteXPC.

The native tunnel and DVT channel are closed after launch. The device owns the
runner's lifetime; this command does not hold a Mac-side XCTest process open.
"""

import argparse
import asyncio
import json
import re

from pymobiledevice3.remote.native_tunnel import NativeRemotedTunnel
from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
from pymobiledevice3.services.dvt.instruments.process_control import ProcessControl


BUNDLE_ID = "agency.ziplyne.taplyne.wda.xctrunner"


async def launch(udid):
    async with NativeRemotedTunnel(serial=udid) as tunnel:
        async with DvtProvider(tunnel) as dvt, ProcessControl(dvt) as process:
            pid = await process.launch(
                bundle_id=BUNDLE_ID,
                kill_existing=True,
                environment={
                    "USE_IP": "127.0.0.1",
                    "USE_PORT": "8100",
                    "WDA_PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
                },
                extra_options={"ActivateSuspended": True},
            )
            if not pid:
                raise RuntimeError("RemoteXPC did not return a runner process ID")
            return pid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--udid", required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9-]+", args.udid):
        parser.error("provide one device UDID")
    pid = asyncio.run(launch(args.udid))
    print(json.dumps({"event": "runner_background_pid", "pid": pid}), flush=True)


if __name__ == "__main__":
    main()
