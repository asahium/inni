#!/usr/bin/env python3
"""A second sync client for Inni's sync tests, using Anki's own backend.

usage: sync_peer.py seed|check|modify COLLECTION
env:   INNI_SYNC_SERVER (e.g. http://127.0.0.1:27701/), INNI_SYNC_USER, INNI_SYNC_PASS
Prints the collection state as JSON after each step.
"""
import json
import os
import sys
import time

from anki.collection import Collection
from anki.sync_pb2 import SyncCollectionResponse

Req = SyncCollectionResponse.ChangesRequired


def login(col):
    return col.sync_login(os.environ.get("INNI_SYNC_USER", "test"), os.environ.get("INNI_SYNC_PASS", "pass"),
                          os.environ["INNI_SYNC_SERVER"])


def sync(col, auth, prefer_upload=False):
    out = col.sync_collection(auth, sync_media=False)
    if out.required in (Req.FULL_SYNC, Req.FULL_UPLOAD, Req.FULL_DOWNLOAD):
        upload = out.required == Req.FULL_UPLOAD or (out.required == Req.FULL_SYNC and prefer_upload)
        col.close_for_full_sync()
        col.full_upload_or_download(auth=auth, server_usn=out.server_media_usn, upload=upload)
        col.reopen(after_full_sync=True)
        return "upload" if upload else "download"
    return Req.Name(out.required)


def state(col, synced):
    problems, _ = col.fix_integrity()
    basic = col.models.by_name("Basic")
    media = sorted(f for f in os.listdir(col.media.dir()) if not f.startswith("."))
    return {
        "synced": synced,
        "notes": col.note_count(),
        "cards": col.card_count(),
        "revlog": col.db.scalar("select count() from revlog"),
        "decks": sorted(d.name for d in col.decks.all_names_and_ids()),
        "fronts": sorted(col.get_note(nid)["Front"] for nid in col.find_notes("note:Basic")),
        "tags": sorted(col.tags.all()),
        "basicCss": basic["css"],
        "basicFields": [f["name"] for f in basic["flds"]],
        "fsrsParams": col.decks.get_config(1)["fsrsParams6"],
        "media": media,
        "problems": [p for p in problems.splitlines() if p and "Database rebuilt" not in p],
    }


def main():
    step, path = sys.argv[1], sys.argv[2]
    col = Collection(path)
    auth = login(col)
    if step == "seed":
        basic = col.models.by_name("Basic")
        did = col.decks.id("Peer::Sub")
        for i in range(3):
            n = col.new_note(basic)
            n["Front"], n["Back"] = f"peer {i}", f"answer {i} <img src=\"peer.png\">"
            n.tags = ["peer"]
            col.add_note(n, did)
        cloze = col.models.by_name("Cloze")
        n = col.new_note(cloze)
        n["Text"] = "{{c1::Paris}} is the capital of {{c2::France}}"
        col.add_note(n, 1)
        conf = col.decks.get_config(1)
        conf["fsrsParams6"] = [0.2, 1.2, 3.0, 15.5, 7.1, 0.5, 1.4, 0.01, 1.5, 0.12, 1.0, 1.9, 0.11, 0.29, 2.2, 0.23, 3.0, 0.5, 0.66, 0.1, 0.5]
        col.decks.update_config(conf)
        with open(os.path.join(col.media.dir(), "peer.png"), "wb") as f:
            f.write(b"\x89PNG\r\n\x1a\nfake image from peer")
        col.decks.select(did)
        card = col.sched.getCard()
        if card:
            col.sched.answerCard(card, 3)
        synced = sync(col, auth, prefer_upload=True)
    elif step == "check":
        synced = sync(col, auth)
    elif step == "modify":
        synced = sync(col, auth)
        basic = col.models.by_name("Basic")
        n = col.new_note(basic)
        n["Front"], n["Back"] = "from anki", "back"
        col.add_note(n, col.decks.id("Peer::Sub"))
        nid = col.find_notes('"Front:peer 1"')[0]
        note = col.get_note(nid)
        note["Front"] = "peer 1 edited"
        col.update_note(note)
        col.remove_notes(col.find_notes('"Front:peer 2"'))
        deck = col.decks.by_name("Peer::Sub")
        deck["name"] = "Peer::Renamed"
        col.decks.save(deck)
        with open(os.path.join(col.media.dir(), "anki.txt"), "w") as f:
            f.write("added in anki")
        synced = sync(col, auth)
    else:
        raise SystemExit(f"unknown step {step}")
    col.sync_media(auth)
    while col.media_sync_status().active:
        time.sleep(0.05)
    print(json.dumps(state(col, synced)))
    col.close()


if __name__ == "__main__":
    main()
