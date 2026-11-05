from PIL import Image, ImageDraw, ImageFont

W, H = 1200, 630
BG     = (11, 18, 32)
CARD   = (17, 26, 43)
BORDER = (34, 48, 74)
TITLE  = (242, 246, 255)
DIM    = (159, 179, 209)
MUTED  = (122, 142, 172)
ACCENT = (79, 140, 255)
GREEN  = (110, 214, 168)
PILL   = (24, 36, 58)

img = Image.new("RGB", (W, H), BG)
d = ImageDraw.Draw(img)

for x in range(0, W, 40):
    d.line([(x, 0), (x, H)], fill=(17, 25, 40), width=1)
for y in range(0, H, 40):
    d.line([(0, y), (W, y)], fill=(17, 25, 40), width=1)

glow = Image.new("L", (W, H), 0)
ImageDraw.Draw(glow).ellipse([-280, -320, 420, 200], fill=40)
img.paste(Image.new("RGB", (W, H), ACCENT), (0, 0), glow.point(lambda v: v // 3))

f_title = ImageFont.truetype("C:/Windows/Fonts/segoeuib.ttf", 92)
f_sub   = ImageFont.truetype("C:/Windows/Fonts/msyhbd.ttc", 36)
f_desc  = ImageFont.truetype("C:/Windows/Fonts/msyh.ttc", 24)
f_chip  = ImageFont.truetype("C:/Windows/Fonts/msyh.ttc", 21)
f_code  = ImageFont.truetype("C:/Windows/Fonts/consola.ttf", 22)
f_label = ImageFont.truetype("C:/Windows/Fonts/consola.ttf", 19)

# 左侧文案区（右边界控制在 600 以内，绝不进卡片）
d.text((72, 96), "AdSpeeder", font=f_title, fill=TITLE)
d.rounded_rectangle([76, 216, 196, 224], radius=4, fill=ACCENT)
d.text((74, 256), "支付宝小游戏 · 激励广告直通", font=f_sub, fill=DIM)
d.text((74, 320), "show() 不发原生请求", font=f_desc, fill=MUTED)
d.text((74, 358), "直接回调 onClose(isEnded: true)", font=f_desc, fill=MUTED)
d.text((74, 396), "单文件 440 行 · 无网络请求", font=f_desc, fill=MUTED)

# 右上角标签
pill = "iOS 15+ · arm64 · MIT"
tw = d.textlength(pill, font=f_chip)
d.rounded_rectangle([W - 72 - tw - 40, 66, W - 72, 112], radius=23, fill=PILL, outline=BORDER)
d.text((W - 72 - tw - 20, 78), pill, font=f_chip, fill=DIM)

# 代码卡片
x0, y0, x1, y1 = 646, 196, 1130, 524
d.rounded_rectangle([x0, y0, x1, y1], radius=18, fill=CARD, outline=BORDER, width=2)
d.text((x0 + 26, y0 + 20), "game.js", font=f_label, fill=MUTED)

rows = [
    ("ad.show();",                 TITLE, f_code, 56),
    ("  // shim intercepts here",  MUTED, f_code, 30),
    ("onClose({",                  GREEN, f_code, 34),
    ("  isEnded:   true,",         GREEN, f_code, 30),
    ("  count:     1,",            GREEN, f_code, 30),
    ("  completed: true",          GREEN, f_code, 30),
    ("});",                        GREEN, f_code, 28),
]
yy = y0 + 52
for text, color, font, gap in rows:
    d.text((x0 + 26, yy), text, font=font, fill=color)
    yy += gap

# 底部 chip
chips = ["Objective-C runtime", "WKWebView JS bridge", "Theos / TrollFools"]
cx = 74
for c in chips:
    w = d.textlength(c, font=f_chip)
    d.rounded_rectangle([cx, 552, cx + w + 34, 596], radius=22, fill=PILL, outline=BORDER)
    d.text((cx + 17, 562), c, font=f_chip, fill=DIM)
    cx += w + 50

img.save("assets/social-preview.png", "PNG")
print("saved", img.size)
