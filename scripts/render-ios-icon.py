from pathlib import Path

from PIL import Image, ImageDraw


# Draw on a larger canvas and downsample to keep the paper edges clean.
size = 3072
icon = Image.new("RGB", (size, size), "#26372E")
draw = ImageDraw.Draw(icon)


def points(coordinates):
    return [(round(x * size / 108), round(y * size / 108)) for x, y in coordinates]


draw.polygon(points([(32, 25), (66, 25), (77, 36), (77, 80), (32, 80)]), fill="#F4E8D3")
draw.polygon(points([(66, 25), (66, 36), (77, 36)]), fill="#AD714D")
for top, right in [(48, 67), (59, 67), (70, 57)]:
    draw.rectangle(points([(41, top), (right, top + 4)]), fill="#AD714D")

app_icon = Path(__file__).resolve().parents[1] / "ios/Pocket/Assets.xcassets/AppIcon.appiconset"
icon.resize((1024, 1024), Image.Resampling.LANCZOS).save(app_icon / "Icon.png", optimize=True)
