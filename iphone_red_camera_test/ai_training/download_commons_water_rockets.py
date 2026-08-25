"""Download license-attributed water-rocket images from Wikimedia Commons.

The downloader only consumes the Commons category API and records the license,
author, source page and original URL next to every image.  It deliberately
skips SVG/GIF/video files because the detector is trained from photographic
raster frames.
"""

from __future__ import annotations

import argparse
import hashlib
import html
import json
import re
import sys
import time
from pathlib import Path
from urllib.parse import urlparse

import requests


API = "https://commons.wikimedia.org/w/api.php"
USER_AGENT = "SE-Water-Rocket-Tracker/1.0 (dataset preparation)"
RASTER_SUFFIXES = {".jpg", ".jpeg", ".png", ".webp"}


def plain_text(value: str) -> str:
    value = re.sub(r"<[^>]+>", " ", html.unescape(value or ""))
    return " ".join(value.split())


def get_json(session: requests.Session, params: dict) -> dict:
    for attempt in range(7):
        response = session.get(API, params=params, timeout=30)
        if response.status_code == 429 or response.status_code >= 500:
            time.sleep(min(30.0, 1.5 * (2 ** attempt)))
            continue
        response.raise_for_status()
        return response.json()
    raise RuntimeError("Wikimedia API remained rate-limited after retries")


def category_files(session: requests.Session, category: str) -> list[str]:
    titles: list[str] = []
    params = {
        "action": "query",
        "format": "json",
        "list": "categorymembers",
        "cmtitle": f"Category:{category}",
        "cmnamespace": 6,
        "cmlimit": "max",
    }
    while True:
        payload = get_json(session, params)
        titles.extend(item["title"] for item in payload["query"]["categorymembers"])
        continuation = payload.get("continue")
        if not continuation:
            return titles
        params.update(continuation)


def image_metadata(session: requests.Session, title: str) -> dict | None:
    params = {
        "action": "query",
        "format": "json",
        "prop": "imageinfo|info",
        "titles": title,
        "iiprop": "url|size|mime|extmetadata",
        "iiurlwidth": 1600,
        "inprop": "url",
    }
    payload = get_json(session, params)
    page = next(iter(payload.get("query", {}).get("pages", {}).values()), None)
    if not page or "imageinfo" not in page:
        return None
    info = page["imageinfo"][0]
    extension = Path(urlparse(info["url"]).path).suffix.lower()
    if extension not in RASTER_SUFFIXES:
        return None
    ext = info.get("extmetadata", {})

    def metadata_value(name: str) -> str:
        return plain_text(ext.get(name, {}).get("value", ""))

    return {
        "title": title,
        "page_url": page.get("canonicalurl") or page.get("fullurl") or "",
        "original_url": info["url"],
        "download_url": info.get("thumburl", info["url"]),
        "width": int(info.get("width", 0)),
        "height": int(info.get("height", 0)),
        "mime": info.get("mime", ""),
        "license": metadata_value("LicenseShortName"),
        "license_url": metadata_value("LicenseUrl"),
        "artist": metadata_value("Artist"),
        "credit": metadata_value("Credit"),
        "attribution": metadata_value("Attribution"),
        "usage_terms": metadata_value("UsageTerms"),
        "description": metadata_value("ImageDescription"),
        "extension": extension,
    }


def download(session: requests.Session, metadata: dict, destination: Path) -> Path:
    digest = hashlib.sha1(metadata["title"].encode("utf-8")).hexdigest()[:12]
    filename = f"commons_{digest}{metadata['extension']}"
    output = destination / filename
    if output.exists() and output.stat().st_size > 0:
        return output
    temporary = output.with_suffix(output.suffix + ".part")
    for attempt in range(7):
        response = session.get(metadata["download_url"], stream=True, timeout=90)
        if response.status_code == 429 or response.status_code >= 500:
            response.close()
            time.sleep(min(30.0, 1.5 * (2 ** attempt)))
            continue
        response.raise_for_status()
        with response, temporary.open("wb") as handle:
            for chunk in response.iter_content(1024 * 256):
                if chunk:
                    handle.write(chunk)
        break
    else:
        raise RuntimeError("Image download remained rate-limited after retries")
    temporary.replace(output)
    return output


def main() -> None:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    parser = argparse.ArgumentParser()
    parser.add_argument("--category", default="Water rockets")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--limit", type=int, default=0, help="0 means every image")
    args = parser.parse_args()

    images = args.output.resolve() / "images"
    images.mkdir(parents=True, exist_ok=True)
    metadata_path = args.output.resolve() / "metadata.jsonl"
    attribution_path = args.output.resolve() / "ATTRIBUTION.tsv"
    session = requests.Session()
    session.headers["User-Agent"] = USER_AGENT

    titles = category_files(session, args.category)
    if args.limit > 0:
        titles = titles[: args.limit]

    rows: list[dict] = []
    for index, title in enumerate(titles, 1):
        try:
            metadata = image_metadata(session, title)
            if metadata is None:
                continue
            output = download(session, metadata, images)
            metadata["local_file"] = output.name
            rows.append(metadata)
            print(f"[{index}/{len(titles)}] {output.name}: {title}")
            time.sleep(0.45)
        except Exception as exception:
            print(f"SKIP {title}: {exception}")

    with metadata_path.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")
    with attribution_path.open("w", encoding="utf-8", newline="") as handle:
        handle.write("file\ttitle\tartist\tlicense\tlicense_url\tpage_url\n")
        for row in rows:
            values = [
                row["local_file"], row["title"], row["artist"], row["license"],
                row["license_url"], row["page_url"],
            ]
            handle.write("\t".join(value.replace("\t", " ") for value in values) + "\n")
    print(f"Downloaded {len(rows)} attributed raster images to {images}")


if __name__ == "__main__":
    main()
