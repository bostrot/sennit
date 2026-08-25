#!/usr/bin/env python3
"""Fills a Matrix account with conversations for app-store review.

App reviewers open Braid to whatever the account holds. An empty inbox
reads as a broken app and gives them nothing to evaluate, so the review
account needs to look like someone actually uses it — and to resemble the
store screenshots, which reviewers compare against.

Two accounts are needed: the one the reviewer signs in to, and a partner
whose messages arrive from the other side. Passwords come from the
environment so they are never written into a file or shell history:

    export BRAID_SEED_SERVER=https://matrix.example.org
    export BRAID_SEED_USER=demo
    export BRAID_SEED_PASSWORD=...
    export BRAID_SEED_PARTNER=demo-partner
    export BRAID_SEED_PARTNER_PASSWORD=...
    python3 tooling/scripts/seed_review_account.py

Re-running is safe: rooms carrying this script's marker topic are reused
rather than duplicated, so the inbox does not fill with copies.

Standard library only — no pip install on whatever machine runs this.
"""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.request

MARKER = "braid-review-seed"


def env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        sys.exit(f"{name} is not set — see the docstring at the top of this file.")
    return value


class Client:
    """The slice of the Matrix client-server API this script needs."""

    def __init__(self, server: str, user: str, password: str) -> None:
        self.server = server.rstrip("/")
        body = self._post(
            "/_matrix/client/v3/login",
            {
                "type": "m.login.password",
                "identifier": {"type": "m.id.user", "user": user},
                "password": password,
            },
        )
        self.token = body["access_token"]
        self.user_id = body["user_id"]
        self._txn = int(time.time() * 1000)

    def _request(self, method: str, path: str, payload=None):
        url = f"{self.server}{path}"
        data = None if payload is None else json.dumps(payload).encode()
        request = urllib.request.Request(url, data=data, method=method)
        request.add_header("Content-Type", "application/json")
        token = getattr(self, "token", None)
        if token:
            request.add_header("Authorization", f"Bearer {token}")
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.loads(response.read() or b"{}")
        except urllib.error.HTTPError as error:
            detail = error.read().decode(errors="replace")
            raise SystemExit(f"{method} {path} failed: {error.code} {detail}")

    def _post(self, path: str, payload):
        return self._request("POST", path, payload)

    def set_display_name(self, name: str) -> None:
        self._request(
            "PUT",
            f"/_matrix/client/v3/profile/{self.user_id}/displayname",
            {"displayname": name},
        )

    def joined_rooms(self) -> list[str]:
        return self._request("GET", "/_matrix/client/v3/joined_rooms")["joined_rooms"]

    def room_topic(self, room_id: str) -> str:
        try:
            state = self._request(
                "GET", f"/_matrix/client/v3/rooms/{room_id}/state/m.room.topic"
            )
        except SystemExit:
            return ""
        return state.get("topic", "")

    def create_room(self, name: str, invite: list[str], direct: bool) -> str:
        body = self._post(
            "/_matrix/client/v3/createRoom",
            {
                "name": name,
                "topic": MARKER,
                "invite": invite,
                "is_direct": direct,
                "preset": "trusted_private_chat",
            },
        )
        return body["room_id"]

    def join(self, room_id: str) -> None:
        self._post(f"/_matrix/client/v3/join/{room_id}", {})

    def send(self, room_id: str, text: str) -> None:
        self._txn += 1
        self._request(
            "PUT",
            f"/_matrix/client/v3/rooms/{room_id}/send/m.room.message/{self._txn}",
            {"msgtype": "m.text", "body": text},
        )

    def mark_direct(self, rooms: dict[str, list[str]]) -> None:
        self._request(
            "PUT",
            f"/_matrix/client/v3/user/{self.user_id}/account_data/m.direct",
            rooms,
        )


# Who says what, in order. "them" is the partner account, "me" the reviewer's.
CONVERSATIONS = [
    (
        "Anna Maven",
        True,
        [
            ("them", "Morning! Did you get a chance to look at the draft?"),
            ("me", "Yes, reviewing now."),
            ("them", "Are we still meeting Thursday?"),
            ("me", "Thursday works. Same time?"),
            ("them", "Perfect, see you then."),
            ("them", "Can you send the summary over when you have it?"),
        ],
    ),
    (
        "Konrad Majewski",
        True,
        [
            ("them", "Hey, are we still on for Thursday?"),
            ("me", "Yes — I'll bring the notes."),
        ],
    ),
    (
        "Sofia Martinez",
        True,
        [
            ("me", "Sent the files over."),
            ("them", "Got them, thanks for switching."),
            ("me", "Let me know when it's done."),
        ],
    ),
    (
        "Design Team",
        False,
        [
            ("them", "Pushed the new rail animation"),
            ("me", "Looks much smoother, nice."),
            ("them", "Ready for review whenever you are."),
        ],
    ),
]


def main() -> None:
    server = env("BRAID_SEED_SERVER")
    me = Client(server, env("BRAID_SEED_USER"), env("BRAID_SEED_PASSWORD"))
    them = Client(
        server, env("BRAID_SEED_PARTNER"), env("BRAID_SEED_PARTNER_PASSWORD")
    )
    print(f"signed in as {me.user_id} and {them.user_id}")

    me.set_display_name("Braid Demo")
    them.set_display_name("Anna Maven")

    existing = {}
    for room_id in me.joined_rooms():
        if me.room_topic(room_id) == MARKER:
            existing[room_id] = True
    if existing:
        print(f"{len(existing)} seeded room(s) already present — reusing, not adding")
        return

    directs: dict[str, list[str]] = {}
    for name, is_direct, script in CONVERSATIONS:
        room_id = me.create_room(name, [them.user_id], is_direct)
        them.join(room_id)
        if is_direct:
            directs.setdefault(them.user_id, []).append(room_id)
        for speaker, text in script:
            (me if speaker == "me" else them).send(room_id, text)
            time.sleep(0.4)  # keeps the timeline order stable and readable
        print(f"seeded {name}")

    if directs:
        me.mark_direct(directs)
    print("\nDone. Sign in as the review account to check the inbox looks right.")


if __name__ == "__main__":
    main()
