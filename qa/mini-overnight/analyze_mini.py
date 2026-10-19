#!/usr/bin/env python3
"""Runs the ux-sim analyzer (qa/ux-sim/analyze.py) against the mini-overnight personas.

Expects qa/mini-overnight/<p>.json and qa/mini-overnight/out/<p>.plans.jsonl (from ribbon-sim).
Writes qa/mini-overnight/out/<p>.trace.txt, <p>.problems.txt, metrics.json.
Run: python3 qa/mini-overnight/analyze_mini.py
"""
import importlib.util
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
QA = os.path.dirname(HERE)
spec = importlib.util.spec_from_file_location("ux_analyze", os.path.join(QA, "ux-sim", "analyze.py"))
an = importlib.util.module_from_spec(spec)
spec.loader.exec_module(an)
an.HERE = HERE  # analyzer reads <HERE>/<persona>.json and writes <HERE>/out/

PERSONAS = ["g1_parent_school_mail_chat", "g2_writer_research_fullwidth", "g3_support_20_chat_windows"]

allm = {}
for p in PERSONAS:
    m, probs = an.run(p)
    allm[p] = an.summarize(m)
    allm[p]["invariant_problems"] = len(probs)
    with open(os.path.join(HERE, "out", p + ".problems.txt"), "w") as fh:
        fh.write("\n".join(probs) + ("\n" if probs else ""))
with open(os.path.join(HERE, "out", "metrics.json"), "w") as fh:
    json.dump(allm, fh, indent=1)
for p, s in allm.items():
    print(p, json.dumps(s))
