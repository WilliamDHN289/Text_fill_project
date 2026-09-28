"""Build the anonymized, paper-ready top panel of the teaser figure.

Input : 00_raw_full.png (2880x1800 macOS screenshot of the deployed GUI)
Output: teaser_top.png  (white-background, rounded panel + soft shadow)

Steps: (1) redraw the recipient avatar + name pill with a pseudonym so the
"who you are writing to" signal survives while the real name/initials do
not; (2) crop to the conversation panel only, dropping the whole sidebar
(which holds every piece of PII: full name, phone, email, message
previews); (3) round the panel corners and mount on white with a soft
shadow so a dark chat panel sits cleanly in a white-background paper.
"""

from PIL import Image, ImageDraw, ImageFont, ImageFilter

FIG = "/Users/denghaonan/Desktop/Text_Fill_Project/1_memory_layer/9_AAAI/figures"
BG = (30, 30, 30)
PSEUDO_NAME = "Alex"        # first name shown in the recipient pill
PSEUDO_INITIALS = "AR"      # avatar initials (Alex Reed)

im = Image.open(f"{FIG}/00_raw_full.png").convert("RGB")
d = ImageDraw.Draw(im)

def font(path, size):
    return ImageFont.truetype(path, size)

SF      = "/System/Library/Fonts/SFNS.ttf"
ARIALB  = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"

# --- 1a. blank the header zone (avatar + real name pill) -------------------
d.rectangle((1668, 496, 1842, 634), fill=BG)

# --- 1b. redraw avatar: vertical purple gradient masked to a circle --------
cx, cy, r = 1748, 542, 46
grad = Image.new("RGB", (2 * r, 2 * r))
gp = grad.load()
top, bot = (112, 106, 132), (72, 66, 96)
for yy in range(2 * r):
    t = yy / (2 * r - 1)
    col = tuple(int(top[i] + (bot[i] - top[i]) * t) for i in range(3))
    for xx in range(2 * r):
        gp[xx, yy] = col
mask = Image.new("L", (2 * r, 2 * r), 0)
ImageDraw.Draw(mask).ellipse((0, 0, 2 * r - 1, 2 * r - 1), fill=255)
im.paste(grad, (cx - r, cy - r), mask)

# avatar initials, centered
fa = font(ARIALB, 38)
bb = d.textbbox((0, 0), PSEUDO_INITIALS, font=fa)
d.text((cx - (bb[2] - bb[0]) / 2, cy - (bb[3] - bb[1]) / 2 - bb[1]),
       PSEUDO_INITIALS, font=fa, fill=(255, 255, 255))

# --- 1c. redraw recipient name pill ---------------------------------------
fp = font(ARIALB, 30)
name_w = d.textbbox((0, 0), PSEUDO_NAME, font=fp)[2]
chev = " ›"
chev_w = d.textbbox((0, 0), chev, font=fp)[2]
pad_x, pill_h = 26, 50
pill_w = name_w + chev_w + 2 * pad_x
px0 = cx - pill_w // 2
py0 = 599 - pill_h // 2
d.rounded_rectangle((px0, py0, px0 + pill_w, py0 + pill_h),
                    radius=pill_h // 2, fill=(58, 58, 60))
tb = d.textbbox((0, 0), PSEUDO_NAME, font=fp)
ty = 599 - (tb[3] + tb[1]) / 2
d.text((px0 + pad_x, ty), PSEUDO_NAME, font=fp, fill=(255, 255, 255))
d.text((px0 + pad_x + name_w, ty), chev, font=fp, fill=(150, 150, 152))

# --- 2. crop to the conversation panel (drops the sidebar / all PII) -------
panel = im.crop((1065, 500, 2434, 1112))

# --- 3. round corners, mount on white with a soft shadow ------------------
rad = 22
pm = Image.new("L", panel.size, 0)
ImageDraw.Draw(pm).rounded_rectangle((0, 0, panel.size[0] - 1, panel.size[1] - 1),
                                     radius=rad, fill=255)
panel.putalpha(pm)

pad, shx, shy, blur = 70, 0, 10, 22
W = panel.size[0] + 2 * pad
H = panel.size[1] + 2 * pad
canvas = Image.new("RGB", (W, H), (255, 255, 255))

shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
sd = ImageDraw.Draw(shadow)
sd.rounded_rectangle((pad + shx, pad + shy, pad + shx + panel.size[0],
                      pad + shy + panel.size[1]), radius=rad,
                     fill=(0, 0, 0, 90))
shadow = shadow.filter(ImageFilter.GaussianBlur(blur))
canvas.paste(shadow, (0, 0), shadow)
canvas.paste(panel, (pad, pad), panel)

# hairline border on the panel edge for definition on white
ImageDraw.Draw(canvas).rounded_rectangle(
    (pad, pad, pad + panel.size[0] - 1, pad + panel.size[1] - 1),
    radius=rad, outline=(210, 210, 214), width=2)

canvas.save(f"{FIG}/teaser_top.png")
print("teaser_top.png", canvas.size)
