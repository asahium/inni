"""Reference data from the official Anki backend, for InniCore's compatibility tests.

Usage: python scripts/oracle.py <collection.anki2> <outdir>
Works on a copy of the collection; never touches the original.
"""
import json
import os
import random
import shutil
import sys

from anki.collection import Collection, ExportAnkiPackageOptions

src, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
path = os.path.join(out, "oracle.anki2")
for suffix in ["", "-wal", "-shm"]:
    if os.path.exists(path + suffix):
        os.remove(path + suffix)
shutil.copy(src, path)
if os.path.exists(src + "-wal"):
    shutil.copy(src + "-wal", path + "-wal")

col = Collection(path)
col.close(downgrade=False)
shutil.copy(path, os.path.join(out, "inni.anki2"))
col = Collection(path)

# Deck list counts
counts = {}
def walk(node):
    if node.deck_id:
        counts[str(node.deck_id)] = [node.new_count, node.learn_count, node.review_count]
    for c in node.children:
        walk(c)
walk(col.sched.deck_due_tree())

# Rendering
rng = random.Random(7)
cids = col.db.list("select id from cards")
rendered = []
for cid in rng.sample(cids, min(400, len(cids))):
    card = col.get_card(cid)
    out_ = card.render_output(reload=True)
    rendered.append({"cid": cid, "q": out_.question_text, "a": out_.answer_text})

# FSRS memory states (default parameters unless the preset has its own)
reviewed = col.db.list("select distinct cid from revlog where ease between 1 and 4")
memory = []
for cid in rng.sample(reviewed, min(300, len(reviewed))):
    try:
        st = col._backend.compute_memory_state(cid)
    except Exception as e:
        continue
    if st.HasField("state"):
        memory.append({"cid": cid, "s": st.state.stability, "d": st.state.difficulty})

# SM-2 next intervals (fuzz is applied on Anki's side; Inni checks the range)
states = []
for cid in rng.sample(cids, min(300, len(cids))):
    card = col.get_card(cid)
    if card.queue < 0:
        continue
    s = col._backend.get_scheduling_states(cid)
    def secs(state):
        n = state.normal if state.HasField("normal") else state.filtered.rescheduling.original_state
        kind = n.WhichOneof("kind")
        if kind == "new":
            return 0
        if kind == "learning":
            return n.learning.scheduled_secs
        if kind == "review":
            return n.review.scheduled_days * 86400
        if kind == "relearning":
            return n.relearning.learning.scheduled_secs
    states.append({"cid": cid, "again": secs(s.again), "hard": secs(s.hard), "good": secs(s.good), "easy": secs(s.easy)})

json.dump({"counts": counts, "rendered": rendered, "memory": memory, "states": states,
           "today": col.sched.today, "fsrs": col.get_config("fsrs", False)},
          open(os.path.join(out, "oracle.json"), "w"), ensure_ascii=False)

# Packages in both formats for the import tests
did = max(col.decks.all_names_and_ids(), key=lambda d: col.db.scalar("select count() from cards where did = ?", d.id)).id
for legacy in (False, True):
    opts = ExportAnkiPackageOptions(with_scheduling=True, with_deck_configs=False, with_media=True, legacy=legacy)
    col.export_anki_package(out_path=os.path.join(out, "legacy.apkg" if legacy else "latest.apkg"), options=opts,
                            limit=col.decks.get(did) and __import__("anki.collection").collection.DeckIdLimit(did))
col.close()
print("ok", len(counts), "decks", len(rendered), "cards", len(memory), "memory states", len(states), "states")
