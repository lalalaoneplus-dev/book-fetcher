#!/usr/bin/env python3
"""Read or assign Book Fetcher TestFlight builds using App Store Connect API credentials."""

from __future__ import annotations

import argparse
import os
import time
from pathlib import Path

import jwt
import requests

API = "https://api.appstoreconnect.apple.com/v1"
APP_ID = "6792689817"


def token() -> str:
    key_id = os.environ["ASC_KEY_ID"]
    issuer = os.environ["ASC_ISSUER_ID"]
    private_key = Path(os.environ["ASC_API_KEY_PATH"]).read_text()
    now = int(time.time())
    return jwt.encode(
        {"iss": issuer, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
        private_key,
        algorithm="ES256",
        headers={"kid": key_id, "typ": "JWT"},
    )


def request(method: str, path: str, **kwargs):
    response = requests.request(
        method,
        API + path,
        headers={"Authorization": f"Bearer {token()}", "Content-Type": "application/json"},
        timeout=45,
        **kwargs,
    )
    response.raise_for_status()
    return response.json() if response.content else {}


def latest(version: str) -> dict | None:
    result = request(
        "GET",
        "/builds",
        params={"filter[app]": APP_ID, "filter[version]": version, "sort": "-uploadedDate", "limit": "5"},
    )
    builds = result.get("data", [])
    return builds[0] if builds else None


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("version")
    parser.add_argument("--assign-group")
    args = parser.parse_args()
    build = latest(args.version)
    if not build:
        print("not-visible")
        return
    attributes = build["attributes"]
    print(f"id={build['id']} version={attributes.get('version')} state={attributes.get('processingState')} uploaded={attributes.get('uploadedDate')}")
    if args.assign_group:
        members = request(
            "GET",
            f"/betaGroups/{args.assign_group}/builds",
            params={"limit": "200"},
        ).get("data", [])
        if not any(item["id"] == build["id"] for item in members):
            request(
                "POST",
                f"/betaGroups/{args.assign_group}/relationships/builds",
                json={"data": [{"type": "builds", "id": build["id"]}]},
            )
            print(f"assigned-group={args.assign_group}")
            members = request(
                "GET",
                f"/betaGroups/{args.assign_group}/builds",
                params={"limit": "200"},
            ).get("data", [])
        print(f"group-readback={'present' if any(item['id'] == build['id'] for item in members) else 'missing'}")
        details = request(
            "GET", "/buildBetaDetails", params={"filter[build]": build["id"], "limit": "1"}
        ).get("data", [])
        if details:
            state = details[0]["attributes"].get("internalBuildState")
            print(f"internal-state={state}")


if __name__ == "__main__":
    main()
