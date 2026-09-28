"""Stack the top (GUI screenshot) and bottom (injected-prompt card) into the
teaser referenced by aaai2027_full.tex (fig:teaser).

Outputs teaser.pdf (for LaTeX) and teaser.png, both at SCALE x resolution:
the bottom card is re-rendered natively at SCALE (crisp vector text) and the
screenshot panel is Lanczos-upscaled to match (its detail is capped by the
source screenshot, but nothing is lost).
"""

from PIL import Image, ImageDraw, ImageFont
import make_teaser_bottom as bottom_mod

FIG = "/Users/denghaonan/Desktop/Text_Fill_Project/1_memory_layer/9_AAAI/figures"
ARIALB = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"

SCALE = 2.0          # 2x -> ~3000px wide; bottom text is truly re-rendered
PDF_DPI = 600        # metadata only; \includegraphics[width=\columnwidth] rules

top = Image.open(f"{FIG}/teaser_top.png").convert("RGB")
top = top.resize((int(top.width * SCALE), int(top.height * SCALE)),
                 Image.LANCZOS)
bot = bottom_mod.render(SCALE).convert("RGB")

overlap = int(96 * SCALE)                 # trim shared white padding
W = max(top.width, bot.width)
H = top.height + bot.height - overlap
canvas = Image.new("RGB", (W, H), (255, 255, 255))
canvas.paste(top, ((W - top.width) // 2, 0))
canvas.paste(bot, ((W - bot.width) // 2, top.height - overlap))

d = ImageDraw.Draw(canvas)
tag = ImageFont.truetype(ARIALB, int(30 * SCALE))
d.text((int(28 * SCALE), int(34 * SCALE)), "(a)", font=tag, fill=(90, 92, 98))
d.text((int(28 * SCALE), top.height - overlap + int(30 * SCALE)), "(b)",
       font=tag, fill=(90, 92, 98))

canvas.save(f"{FIG}/teaser.png")
canvas.save(f"{FIG}/teaser.pdf", "PDF", resolution=PDF_DPI)
print("teaser.png / teaser.pdf", canvas.size,
      f"(~{canvas.width / PDF_DPI:.1f}in natural width @ {PDF_DPI}dpi)")
