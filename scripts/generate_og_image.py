#!/usr/bin/env python3
"""Generate OG image (1200x630) for Chewy website SEO."""

from PIL import Image, ImageDraw, ImageFont, ImageFilter
import os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(SCRIPT_DIR)
LOGO_PATH = os.path.join(ROOT, "logo.png")
OUTPUT_PATH = os.path.join(ROOT, "docs", "assets", "og-image.png")

WIDTH, HEIGHT = 1200, 630

def hex_to_rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i+2], 16) for i in (0, 2, 4))

BG = hex_to_rgb("#0a0a0f")
PRIMARY = hex_to_rgb("#874bfd")
ACCENT = hex_to_rgb("#ff6b9d")
TEXT = hex_to_rgb("#e2e2e8")
TEXT_DIM = hex_to_rgb("#6e6e82")
BORDER = hex_to_rgb("#1e1e2e")

def lerp_color(c1, c2, t):
    return tuple(int(c1[i] + (c2[i] - c1[i]) * t) for i in range(3))

def create_og_image():
    img = Image.new("RGB", (WIDTH, HEIGHT), BG)
    draw = ImageDraw.Draw(img)

    # Subtle gradient glow in the background
    for y in range(HEIGHT):
        for x in range(WIDTH):
            # Distance from top-left glow center (30%, 20%)
            dx1 = (x - WIDTH * 0.3) / WIDTH
            dy1 = (y - HEIGHT * 0.2) / HEIGHT
            d1 = (dx1**2 + dy1**2) ** 0.5

            # Distance from bottom-right glow center (70%, 80%)
            dx2 = (x - WIDTH * 0.7) / WIDTH
            dy2 = (y - HEIGHT * 0.8) / HEIGHT
            d2 = (dx2**2 + dy2**2) ** 0.5

            # Blend glows
            glow1 = max(0, 1 - d1 * 2.5) * 0.15
            glow2 = max(0, 1 - d2 * 2.5) * 0.12

            r, g, b = BG
            r = int(min(255, r + PRIMARY[0] * glow1 + ACCENT[0] * glow2))
            g = int(min(255, g + PRIMARY[1] * glow1 + ACCENT[1] * glow2))
            b = int(min(255, b + PRIMARY[2] * glow1 + ACCENT[2] * glow2))
            img.putpixel((x, y), (r, g, b))

    draw = ImageDraw.Draw(img)

    # Load and place logo
    logo = Image.open(LOGO_PATH).convert("RGBA")
    logo_size = 160
    logo = logo.resize((logo_size, logo_size), Image.LANCZOS)

    # Add rounded corners to logo
    mask = Image.new("L", (logo_size, logo_size), 0)
    mask_draw = ImageDraw.Draw(mask)
    mask_draw.rounded_rectangle([0, 0, logo_size - 1, logo_size - 1], radius=24, fill=255)
    logo.putalpha(mask)

    # Center logo horizontally, position in upper portion
    logo_x = (WIDTH - logo_size) // 2
    logo_y = 100
    img.paste(logo, (logo_x, logo_y), logo)

    # Try to load a nice font, fall back to default
    title_font = None
    subtitle_font = None
    badge_font = None
    font_paths = [
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",
        "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
    ]
    font_paths_regular = [
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
        "/usr/share/fonts/TTF/DejaVuSans.ttf",
    ]

    for fp in font_paths:
        if os.path.exists(fp):
            title_font = ImageFont.truetype(fp, 64)
            badge_font = ImageFont.truetype(fp, 20)
            break

    for fp in font_paths_regular:
        if os.path.exists(fp):
            subtitle_font = ImageFont.truetype(fp, 24)
            break

    if title_font is None:
        title_font = ImageFont.load_default()
        subtitle_font = ImageFont.load_default()
        badge_font = ImageFont.load_default()

    if subtitle_font is None:
        subtitle_font = title_font

    # Title "chewy" with gradient effect (simulate with two-tone)
    title = "chewy"
    title_bbox = draw.textbbox((0, 0), title, font=title_font)
    title_w = title_bbox[2] - title_bbox[0]
    title_x = (WIDTH - title_w) // 2
    title_y = logo_y + logo_size + 30

    # Create gradient text by drawing character by character
    # First draw in primary color, then overlay accent on right side
    # Simple approach: draw full text with gradient
    title_img = Image.new("RGBA", (title_w + 20, 80), (0, 0, 0, 0))
    title_draw = ImageDraw.Draw(title_img)

    # Draw each column with interpolated color
    for i, char in enumerate(title):
        t = i / max(len(title) - 1, 1)
        color = lerp_color(PRIMARY, ACCENT, t)
        char_x = draw.textbbox((0, 0), title[:i], font=title_font)[2] if i > 0 else 0
        title_draw.text((char_x, 0), char, fill=color, font=title_font)

    img.paste(title_img, (title_x, title_y), title_img)

    # Subtitle
    subtitle = "AI image & video generation in your terminal"
    sub_bbox = draw.textbbox((0, 0), subtitle, font=subtitle_font)
    sub_w = sub_bbox[2] - sub_bbox[0]
    sub_x = (WIDTH - sub_w) // 2
    sub_y = title_y + 80
    draw.text((sub_x, sub_y), subtitle, fill=TEXT_DIM, font=subtitle_font)

    # Bottom badge: "chewytui.xyz"
    badge_text = "chewytui.xyz"
    badge_bbox = draw.textbbox((0, 0), badge_text, font=badge_font)
    badge_w = badge_bbox[2] - badge_bbox[0]
    badge_h = badge_bbox[3] - badge_bbox[1]
    badge_pad_x, badge_pad_y = 20, 10
    badge_x = (WIDTH - badge_w - badge_pad_x * 2) // 2
    badge_y = sub_y + 60

    # Badge background
    draw.rounded_rectangle(
        [badge_x, badge_y, badge_x + badge_w + badge_pad_x * 2, badge_y + badge_h + badge_pad_y * 2],
        radius=20,
        fill=(PRIMARY[0] // 4, PRIMARY[1] // 4, PRIMARY[2] // 4),
        outline=(*PRIMARY, 100),
    )
    draw.text(
        (badge_x + badge_pad_x, badge_y + badge_pad_y),
        badge_text,
        fill=PRIMARY,
        font=badge_font,
    )

    # Bottom decorative line
    line_y = HEIGHT - 4
    for x in range(WIDTH):
        t = x / WIDTH
        color = lerp_color(PRIMARY, ACCENT, t)
        draw.line([(x, line_y), (x, HEIGHT)], fill=color)

    img.save(OUTPUT_PATH, "PNG", optimize=True)
    print(f"OG image saved to {OUTPUT_PATH}")
    print(f"Size: {os.path.getsize(OUTPUT_PATH)} bytes")


if __name__ == "__main__":
    create_og_image()
