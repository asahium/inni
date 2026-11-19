"""Opens what InniCore wrote with the official Anki backend and checks it.

Usage: python scripts/verify_with_anki.py <dir written by CollectionTests.testWriteForAnki>
"""
import json
import os
import sys
import tempfile

from anki.collection import Collection, ImportAnkiPackageOptions, ImportAnkiPackageRequest

d = sys.argv[1]
expected = json.load(open(os.path.join(d, "expected.json")))
ok = True


def check(cond, msg):
    global ok
    print(("ok   " if cond else "FAIL ") + msg)
    ok = ok and cond


# 1. The collection file itself
col = Collection(os.path.join(d, "collection.anki2"))
problems = col.fix_integrity()
check(col.note_count() == expected["notes"], f"notes {col.note_count()} == {expected['notes']}")
check(col.card_count() == expected["cards"], f"cards {col.card_count()} == {expected['cards']}")
check(col.db.scalar("select count() from revlog") == expected["revlog"], "revlog entries")
print("     check database:", problems[0].strip().replace("\n", " | ") or "no problems")
check("Database rebuilt and optimized" in problems[0] or problems[0].strip() == "" or "No problems" in problems[0], "check database clean")
names = sorted(x.name for x in col.decks.all_names_and_ids())
check("Inni::Renamed" in names, f"decks {names}")
for cid in col.find_cards(""):
    c = col.get_card(cid)
    q = c.question()
    check("error" not in q.lower() or "inni" in q.lower(), f"renders card {cid} ({c.note_type()['name']} {c.ord})")
col.sched.deck_due_tree()
col.close()

# 2. Packages
for name, sched in [("inni.apkg", False), ("inni-sched.apkg", True)]:
    tmp = tempfile.mkdtemp()
    col = Collection(os.path.join(tmp, "c.anki2"))
    req = ImportAnkiPackageRequest(package_path=os.path.join(d, name),
                                   options=ImportAnkiPackageOptions(with_scheduling=True, merge_notetypes=False))
    res = col.import_anki_package(req)
    check(len(res.log.new) == expected["notes"], f"{name}: imported {len(res.log.new)} notes")
    media = os.listdir(col.media.dir())
    check("pic.png" in media, f"{name}: media {media}")
    if sched:
        check(col.db.scalar("select count() from revlog") > 0, f"{name}: review history kept")
    else:
        check(col.db.scalar("select count() from cards where type != 0") == 0, f"{name}: scheduling reset")
    col.close()

tmp = tempfile.mkdtemp()
col = Collection(os.path.join(tmp, "c.anki2"))
col.close()
from anki.collection import Collection as C
from anki.importing import *  # noqa
from anki._backend import RustBackend
backend = RustBackend()
backend.import_collection_package(col_path=os.path.join(tmp, "c.anki2"), backup_path=os.path.join(d, "inni.colpkg"),
                                  media_folder=os.path.join(tmp, "media"), media_db=os.path.join(tmp, "media.db"))
col = Collection(os.path.join(tmp, "c.anki2"))
check(col.note_count() == expected["notes"], f"colpkg: {col.note_count()} notes")
check("pic.png" in os.listdir(os.path.join(tmp, "media")), "colpkg: media")
col.close()

print("ALL OK" if ok else "SOME CHECKS FAILED")
sys.exit(0 if ok else 1)
