"""Bottom panel of the teaser: the prompt DPFM assembles on-device.

Faithful to the deployed format:
  - the injected block header is literally "[Relevant memory]"
  - each fact line is "- (date, to <participants>) <text>"  (dpfm.py
    _format_prompt), appended to the userContext section
    (app buildPromptSections)
The panel visually links the retrieved value ("8:00pm") to the ghost-text
completion, so the reader sees WHY the model could copy it verbatim.
This is a typeset reconstruction (not a raw app screenshot) --- it exposes
no real prompt internals and matches the top panel's width/style.

render(scale) draws everything at `scale`x for a crisp, high-resolution
output (all fonts/positions are derived from `scale`, so 2x is genuinely
sharper, not an upscale).
"""

from PIL import Image, ImageDraw, ImageFont

FIG = "/Users/denghaonan/Desktop/Text_Fill_Project/1_memory_layer/9_AAAI/figures"
MONO = "/System/Library/Fonts/SFNSMono.ttf"
SF = "/System/Library/Fonts/SFNS.ttf"
ARIALB = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"

BLUE = (56, 120, 244)      # iMessage-blue accent = the completion / its source
INK = (28, 28, 30)
GREY = (120, 122, 128)
CARD = (246, 247, 249)
BORDER = (208, 210, 216)


def render(scale=1.0):
    S = scale
    def s(v):
        return int(round(v * S))

    W = s(1509)
    PAD = s(70)
    body = ImageFont.truetype(MONO, s(31))
    bodyb = ImageFont.truetype(ARIALB, s(31))
    title = ImageFont.truetype(ARIALB, s(23))

    x0, x1 = PAD, W - PAD
    top = PAD
    line_h = s(46)
    n_body = 6
    div_gap = s(20)
    card_h = s(48) + s(24) + n_body * line_h + div_gap + s(40)
    H = top + card_h + PAD

    canvas = Image.new("RGB", (W, H), (255, 255, 255))
    d = ImageDraw.Draw(canvas)

    d.rounded_rectangle((x0, top, x1, top + card_h), radius=s(20), fill=CARD,
                        outline=BORDER, width=max(1, s(2)))

    tx, ty = x0 + s(34), top + s(26)
    d.text((tx, ty), "PROMPT ASSEMBLED ON-DEVICE", font=title, fill=GREY)
    d.line((x0 + s(34), ty + s(46), x1 - s(34), ty + s(46)), fill=BORDER,
           width=max(1, s(1)))

    cx = x0 + s(42)
    state = {"y": ty + s(74)}

    def mono(txt, color=INK):
        d.text((cx, state["y"]), txt, font=body, fill=color)

    def hl(prefix, token, color=BLUE):
        y = state["y"]
        px = cx + d.textlength(prefix, font=body)
        d.text((cx, y), prefix, font=body, fill=INK)
        tw = d.textlength(token, font=bodyb)
        d.rounded_rectangle((px - s(6), y - s(4), px + tw + s(8), y + s(38)),
                            radius=s(8), fill=(224, 234, 255))
        d.text((px, y), token, font=bodyb, fill=color)
        return px + tw

    # injected memory block
    mono("[Relevant memory]", color=(96, 98, 104))
    state["y"] += line_h
    end = hl("- (Jul 26, to Alex) The concert starts at ", "8:00pm")
    d.text((end, state["y"]), ".", font=body, fill=INK)
    state["y"] += line_h + s(8)

    # live typing context
    mono("context  (writing to Alex):", color=GREY)
    state["y"] += line_h
    q = '  "The concert is at '
    qx = cx + d.textlength(q, font=body)
    d.text((cx, state["y"]), q, font=body, fill=INK)
    d.rectangle((qx, state["y"] - s(2), qx + s(3), state["y"] + s(34)), fill=INK)
    d.text((qx + s(8), state["y"]), '"', font=body, fill=INK)
    state["y"] += line_h + div_gap

    # divider + completion
    d.line((cx, state["y"], x1 - s(34), state["y"]), fill=BORDER, width=max(1, s(1)))
    state["y"] += s(18)
    hl("→ ghost text:  ", "8:00pm.", color=BLUE)

    return canvas


if __name__ == "__main__":
    img = render(1.0)
    img.save(f"{FIG}/teaser_bottom.png")
    print("teaser_bottom.png", img.size)
