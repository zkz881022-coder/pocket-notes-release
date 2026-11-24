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

    def handle_data(self, data):
        self.fragments.append(data)


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
    return feed["title"], set(candidates)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["preflight", "ios", "android"])
    parser.add_argument("feed", type=Path)
    parser.add_argument("seed", type=Path)
    parser.add_argument("evidence", type=Path, nargs="?")
    args = parser.parse_args()

    title, candidates = expected_markers(args.feed, args.seed)
    if args.mode == "preflight":
        return 0
    if args.evidence is None:
        parser.error("ios and android modes require a local observation")

    try:
        if args.mode == "ios":
            state = plistlib.loads(args.evidence.read_bytes())
            actual = json.loads(state["latestPocketFeed"])
            if actual != json.loads(args.feed.read_text(encoding="utf-8")):
                return 1
            seen = {item["title"] for item in actual["items"]}
        else:
            nodes = ET.parse(args.evidence).iter("node")
            seen = {
                value
                for node in nodes
                for key in ("text", "content-desc")
                if (value := node.get(key))
            }
            if title not in seen:
                return 1
        matches = sorted(candidates & seen)
    except (OSError, plistlib.InvalidFileException, ET.ParseError, KeyError, TypeError, ValueError):
        return 1
    if not matches:
        return 1

    print(json.dumps({"title": title, "matched_item": matches[0]}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
