import argparse
import json
import plistlib
from html.parser import HTMLParser
from pathlib import Path
import xml.etree.ElementTree as ET


class SeedText(HTMLParser):
    def __init__(self):
        super().__init__()
        self.fragments = []
        self.markers = []
        self.in_item = False
        self.marker = None

    def handle_starttag(self, tag, attrs):
        if tag == "li":
            self.in_item = True
        if tag in ("h1", "h2") or (tag == "p" and self.in_item):
            self.marker = []

    def handle_endtag(self, tag):
        if self.marker is not None and tag in ("h1", "h2", "p"):
            self.markers.append("".join(self.marker))
            self.marker = None
        if tag == "li":
            self.in_item = False

    def handle_data(self, data):
        self.fragments.append(data)
        if self.marker is not None:
            self.marker.append(data)


def expected_markers(feed_path, seed_path):
    feed = json.loads(feed_path.read_text(encoding="utf-8"))
    if not isinstance(feed, dict) or set(feed) != {"title", "items"} or not isinstance(feed["title"], str):
        raise ValueError("Invalid feed title or fields")
    if not isinstance(feed["items"], list) or any(
        not isinstance(item, dict) or set(item) != {"title", "body"}
        or any(not isinstance(text, str) for text in item.values())
        for item in feed["items"]
    ):
        raise ValueError("Invalid feed items")
    seed = SeedText()
    seed.feed(seed_path.read_text(encoding="utf-8"))
    seed_text = " ".join(seed.fragments)
    candidates = [
        item["title"] for item in feed["items"]
        if item["title"].strip() and item["title"] != feed["title"] and item["title"] not in seed_text
    ]
    if not feed["title"].strip() or not candidates:
        raise ValueError("Feed needs a non-empty title and at least one item title absent from the bundled seed")
    return feed, set(candidates), {normalized(text) for text in seed.markers if text.strip()}


def normalized(text):
    return "".join(text.split())


def filter_android(raw, output, app_id):
    try:
        nodes = ET.parse(raw).getroot()
        top = nodes.find("node")
        if top is None or top.get("package") != app_id:
            return 1
        result = ET.Element("hierarchy")
        for node in nodes.iter("node"):
            if node.get("package") == app_id:
                ET.SubElement(result, "node", {
                    key: node.get(key, "") for key in ("package", "text", "content-desc", "bounds")
                })
        ET.ElementTree(result).write(output, encoding="utf-8", xml_declaration=True)
        return 0
    except (OSError, ET.ParseError):
        return 1


def match_android(paths, app_id, feed, candidates, seed_markers, diagnostic):
    seen = set()
    streams = []
    for path in paths:
        visible = []
        try:
            for node in ET.parse(path).iter("node"):
                if node.get("package") != app_id:
                    continue
                visible.extend(normalized(node.get(key, "")) for key in ("text", "content-desc"))
        except (OSError, ET.ParseError):
            continue
        seen.update(value for value in visible if value)
        streams.append("".join(dict.fromkeys(value for value in visible if value)))

    def displayed(value):
        marker = normalized(value)
        return bool(marker) and (marker in seen or any(marker in stream for stream in streams))

    title_seen = normalized(feed["title"]) in seen
    items_seen = [
        item for item in feed["items"]
        if displayed(item["title"]) and item["body"].strip() and displayed(item["body"])
    ]
    matches = sorted(candidates & {item["title"] for item in items_seen})
    if title_seen and matches:
        status = "matched-current-feed"
    elif title_seen and normalized(feed["title"]) not in seed_markers:
        status = "current-title-seen-without-matching-item"
    elif not seen:
        status = "blank-or-app-not-observable"
    elif (seed_markers - {normalized(feed["title"])}) & seen:
        status = "recognized-bundled-content"
    else:
        status = "app-has-text-but-current-feed-not-confirmed"
    if diagnostic is not None:
        diagnostic.write_text(json.dumps({
            "status": status, "title_seen": title_seen,
            "expected_items_seen": len(items_seen), "expected_items_total": len(feed["items"]),
        }) + "\n", encoding="utf-8")
    if status != "matched-current-feed":
        return 1
    print(json.dumps({"title": feed["title"], "matched_item": matches[0],
                      "verified_items": len(items_seen)}, ensure_ascii=False))
    return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["preflight", "ios", "android", "android-filter"])
    parser.add_argument("feed", type=Path)
    parser.add_argument("seed", type=Path)
    parser.add_argument("evidence", type=Path, nargs="?")
    parser.add_argument("--extra", action="append", type=Path, default=[])
    parser.add_argument("--package")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--diagnostic", type=Path)
    args = parser.parse_args()

    if args.mode == "android-filter":
        if not args.package or args.output is None or args.evidence is None:
            parser.error("android-filter requires a package, input and output")
        return filter_android(args.evidence, args.output, args.package)
    feed, candidates, seed_markers = expected_markers(args.feed, args.seed)
    title = feed["title"]
    if args.mode == "preflight":
        return 0
    if args.mode == "android":
        if not args.package:
            parser.error("android requires an app package")
        evidence = [] if args.evidence is None else [args.evidence]
        return match_android(evidence + args.extra, args.package, feed, candidates, seed_markers, args.diagnostic)
    if args.evidence is None:
        parser.error("ios and android modes require a local observation")

    try:
        state = plistlib.loads(args.evidence.read_bytes())
        actual = json.loads(state["latestPocketFeed"])
        if actual != feed:
            return 1
        seen = {item["title"] for item in actual["items"]}
        matches = sorted(candidates & seen)
    except (OSError, plistlib.InvalidFileException, ET.ParseError, KeyError, TypeError, ValueError):
        return 1
    if not matches:
        return 1

    print(json.dumps({"title": title, "matched_item": matches[0]}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
