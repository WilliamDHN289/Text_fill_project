# figures/ — teaser assets for aaai2027_full.tex

`teaser.png` is the figure referenced by `fig:teaser` (stacked panels a+b).
It is fully anonymized: the recipient is a pseudonym ("Alex" / "AR"), and
the entire iMessage sidebar (which held the real name, phone number, email,
and message previews) was cropped out.

| file | role |
|---|---|
| `teaser.png` | final figure used in the paper (a: GUI, b: injected prompt) |
| `teaser_top.png` | panel (a): anonymized GUI screenshot on white |
| `teaser_bottom.png` | panel (b): typeset `[Relevant memory]` prompt card |
| `make_teaser_top.py` | crop + redraw pseudonymous avatar/name + mount on white |
| `make_teaser_bottom.py` | render the injected-prompt card (format per dpfm.py `_format_prompt`) |
| `make_teaser.py` | stack (a)+(b) → `teaser.png` |

## Regenerate

`make_teaser_top.py` expects the original screenshot copied to
`00_raw_full.png` in this folder. That raw file contains PII (it includes
the sidebar) and is intentionally **not** kept here — copy it back from the
source screenshot before re-running, then delete it again:

```bash
cp "<original screenshot>.png" 00_raw_full.png
python3 make_teaser_top.py && python3 make_teaser_bottom.py && python3 make_teaser.py
rm 00_raw_full.png
```

Panel (b) is a faithful typeset reconstruction of the deployed prompt
format, not a raw app export — it exposes no real prompt internals. To
swap in an actual in-app export instead, replace `teaser_bottom.png` and
rerun `make_teaser.py`.
