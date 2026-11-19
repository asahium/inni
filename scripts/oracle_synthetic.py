"""Synthetic collection with cards in every state, plus Anki's next intervals for SM-2 and FSRS.

Usage: python scripts/oracle_synthetic.py <outdir>
"""
import json
import os
import random
import sys

from anki.collection import Collection

out = sys.argv[1]
os.makedirs(out, exist_ok=True)
rng = random.Random(3)


def build(name, fsrs):
    path = os.path.join(out, name)
    for s in ["", "-wal", "-shm"]:
        if os.path.exists(path + s):
            os.remove(path + s)
    col = Collection(path)
    col.set_config("fsrs", fsrs)
    conf = col.decks.config_dict_for_deck_id(1)
    conf["new"]["delays"] = [1.0, 10.0, 60.0]
    conf["lapse"]["delays"] = [10.0, 30.0]
    conf["lapse"]["mult"] = 0.3
    conf["rev"]["hardFactor"] = 1.2
    conf["rev"]["ease4"] = 1.3
    col.decks.save(conf)
    model = col.models.by_name("Basic")
    today = col.sched.today
    for i in range(400):
        n = col.new_note(model)
        n["Front"] = f"q{i}"
        n["Back"] = f"a{i}"
        col.add_note(n, 1)
    cids = col.db.list("select id from cards order by id")
    for cid in cids:
        kind = rng.choice(["review", "review", "review", "relearn", "learn", "dayLearn"])
        ivl = rng.choice([1, 2, 3, 5, 8, 13, 21, 40, 90, 200, 400])
        factor = rng.choice([1300, 1700, 2100, 2500, 2900, 3500])
        late = rng.choice([0, 0, 1, 3, 10, 40])
        data = ""
        if fsrs:
            data = json.dumps({"s": round(rng.uniform(0.5, 300), 3), "d": round(rng.uniform(1, 10), 3)})
        if kind == "review":
            col.db.execute("update cards set type=2, queue=2, ivl=?, factor=?, due=?, reps=5, lapses=1, data=? where id=?",
                           ivl, factor, today - late, data, cid)
        elif kind == "relearn":
            col.db.execute("update cards set type=3, queue=1, ivl=?, factor=?, due=?, left=?, reps=6, lapses=2, data=? where id=?",
                           ivl, factor, col.sched.day_cutoff - 86400 + 60, rng.choice([1, 2]), data, cid)
        elif kind == "learn":
            col.db.execute("update cards set type=1, queue=1, factor=0, due=?, left=?, reps=1, data=? where id=?",
                           col.sched.day_cutoff - 86400 + 60, rng.choice([1, 2, 3]), data, cid)
        else:
            col.db.execute("update cards set type=1, queue=3, factor=0, due=?, left=?, reps=2, data=? where id=?",
                           today, rng.choice([1, 2]), data, cid)
    col.save() if hasattr(col, "save") else None

    states = []
    for cid in cids:
        s = col._backend.get_scheduling_states(cid)

        def secs(state):
            n = state.normal
            k = n.WhichOneof("kind")
            if k == "learning":
                return n.learning.scheduled_secs
            if k == "review":
                return n.review.scheduled_days * 86400
            if k == "relearning":
                return n.relearning.learning.scheduled_secs
            return 0

        states.append({"cid": cid, "again": secs(s.again), "hard": secs(s.hard), "good": secs(s.good), "easy": secs(s.easy)})
    col.close(downgrade=False)
    json.dump({"states": states}, open(path + ".json", "w"))


build("synthetic-sm2.anki2", False)
build("synthetic-fsrs.anki2", True)
print("ok")
