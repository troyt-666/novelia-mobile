#!/usr/bin/env python3
"""Capture public reading samples locally, then replay their unmodified JSON.

The corpus lives under ignored build/, never in source control. No credentials,
cookies, user library, or prose are printed. Requires curl for capture.
"""

import argparse
import concurrent.futures
import hashlib
import http.server
import json
from pathlib import Path
import subprocess
import time
import urllib.parse

ORIGIN = "https://n.novelia.cc/api/"


def read_json(path):
    return json.loads(path.read_bytes())


def capture(root, include_images=True):
    root.mkdir(parents=True, exist_ok=True)

    def fetch(route, path, query=None):
        if path.exists():
            return read_json(path)
        url = ORIGIN + route
        if query:
            url += "?" + urllib.parse.urlencode(query)
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_suffix(".partial")
        subprocess.run(
            ["curl", "--ipv4", "--fail", "--silent", "--show-error",
             "--connect-timeout", "10", "--max-time", "30",
             url, "--output", str(temporary)], check=True,
        )
        result = read_json(temporary)
        temporary.replace(path)
        return result

    outlines = {}
    for page in range(2):
        data = fetch("novel", root / f"catalog-{page}.json", {
            "page": page, "pageSize": 20, "query": "",
            "provider": "syosetu,kakuyomu", "type": 0,
            "level": 1, "translate": 0, "sort": 0,
        })
        for item in data["items"]:
            outlines[f'{item["providerId"]}/{item["novelId"]}'] = item

    def capture_book(item):
        key = f'{item["providerId"]}/{item["novelId"]}'
        path = root / "books" / key
        try:
            detail = fetch(f"novel/{key}", path / "detail.json")
            chapters = [x["chapterId"] for x in detail["toc"] if x.get("chapterId")]
            if not chapters:
                return None
            chapter = fetch(f"novel/{key}/chapter/{chapters[0]}",
                            path / "chapters" / f"{chapters[0]}.json")
            count = len(chapter["paragraphs"])
            images = sum(p.lstrip().startswith("<图片>") for p in chapter["paragraphs"])
            return {"key": key, "first_chapter": chapters[0],
                    "catalog_chapters": len(chapters), "paragraphs": count,
                    "characters": sum(len(p) for p in chapter["paragraphs"]),
                    "translated": len(chapter.get("sakuraParagraphs", [])) == count,
                    "images": images}
        except (subprocess.CalledProcessError, KeyError, ValueError) as error:
            print(f"Skipped {key}: {type(error).__name__}", flush=True)
            return None

    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
        books = [book for book in executor.map(capture_book, outlines.values()) if book]
    candidates = sorted(
        [b for b in books if b["translated"] and b["images"] == 0 and b["catalog_chapters"] >= 12],
        key=lambda b: b["characters"], reverse=True,
    )
    readers = candidates[:2]
    if len(readers) != 2:
        raise RuntimeError("Need two translated public chapter samples")
    for book in readers:
        key = book["key"]
        path = root / "books" / key
        details = read_json(path / "detail.json")
        ids = [x["chapterId"] for x in details["toc"] if x.get("chapterId")][:12]
        summaries = []
        for chapter_id in ids:
            chapter = fetch(f"novel/{key}/chapter/{chapter_id}",
                            path / "chapters" / f"{chapter_id}.json")
            summaries.append({"id": chapter_id, "paragraphs": len(chapter["paragraphs"]),
                              "characters": sum(len(p) for p in chapter["paragraphs"]),
                              "images": sum(p.lstrip().startswith("<图片>") for p in chapter["paragraphs"]),
                              "translations": {s: len(chapter.get(f"{s}Paragraphs", []))
                                               for s in ["youdao", "gpt", "sakura"]}})
        book["chapters"] = summaries
        book["title"] = details.get("titleZh") or details["titleJp"]
        print(json.dumps(book, ensure_ascii=False), flush=True)
    # Also preserve a real illustrated chapter, including original image bytes.
    illustrated = next((b for b in books if b["images"] and b["translated"]), None)
    images = {}
    if illustrated and include_images:
        book = dict(illustrated)
        path = root / "books" / book["key"]
        chapter = read_json(path / "chapters" / (book["first_chapter"] + ".json"))
        for paragraph in chapter["paragraphs"]:
            if not paragraph.lstrip().startswith("<图片>"):
                continue
            url = paragraph.lstrip().removeprefix("<图片>").strip()
            name = hashlib.sha256(url.encode()).hexdigest() + ".image"
            target = root / "images" / name
            target.parent.mkdir(exist_ok=True)
            if not target.exists() or target.stat().st_size == 0:
                temporary = target.with_suffix(".partial")
                try:
                    subprocess.run(["curl", "--location", "--max-redirs", "5",
                                    "--fail", "--silent", "--show-error",
                                    "--connect-timeout", "10", "--max-time", "30",
                                    url, "--output", str(temporary)], check=True)
                except subprocess.CalledProcessError:
                    print("Illustrated sample unavailable; preserving text samples", flush=True)
                    break
                if temporary.stat().st_size == 0:
                    raise RuntimeError("Empty illustration response")
                temporary.replace(target)
            images[url] = {"file": name, "bytes": target.stat().st_size,
                           "sha256": hashlib.sha256(target.read_bytes()).hexdigest()}
        details = read_json(path / "detail.json")
        book["title"] = details.get("titleZh") or details["titleJp"]
        book["chapters"] = [{"id": book["first_chapter"],
                             "paragraphs": book["paragraphs"],
                             "characters": book["characters"], "images": book["images"]}]
        if len(images) == book["images"]:
            readers.append(book)
    manifest = {"captured_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "origin": ORIGIN, "books": books, "readers": readers, "images": images,
                "files": {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
                          for p in sorted((root / "books").rglob("*.json"))}}
    (root / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2))
    print(f'Captured {len(books)} books, {sum(b["catalog_chapters"] for b in books)} TOC chapters', flush=True)


def serve(root, port):
    manifest = read_json(root / "manifest.json")
    outlines = {f'{x["providerId"]}/{x["novelId"]}': x
                for p in sorted(root.glob("catalog-*.json")) for x in read_json(p)["items"]}
    # Keep the selected article first for the real discovery -> details route.
    selected = [b["key"] for b in manifest["readers"]]
    order = selected + [b["key"] for b in manifest["books"] if b["key"] not in selected]

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            route = urllib.parse.unquote(urllib.parse.urlparse(self.path).path)
            payload = None
            if route == "/manifest":
                payload = dict(manifest)
                config = root / "run-config.json"
                if config.exists():
                    payload["profile"] = read_json(config)
            elif route.startswith("/images/"):
                name = route.removeprefix("/images/")
                path = root / "images" / name
                if name in {v["file"] for v in manifest.get("images", {}).values()}:
                    body = path.read_bytes()
                    self.send_response(200)
                    self.send_header("Content-Type", "application/octet-stream")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                    return
            elif route in ("/api/novel",) or route.startswith("/api/novel/rank/"):
                payload = {"items": [outlines[key] for key in order], "pageNumber": 1}
            elif route == "/api/comment":
                payload = {"items": [], "pageNumber": 0}
            elif route.startswith("/api/novel/"):
                parts = route.removeprefix("/api/novel/").split("/")
                if len(parts) == 2:
                    path = root / "books" / parts[0] / parts[1] / "detail.json"
                elif len(parts) == 4 and parts[2] == "chapter":
                    path = root / "books" / parts[0] / parts[1] / "chapters" / (parts[3] + ".json")
                else:
                    path = None
                if path and path.is_file() and path.resolve().is_relative_to(root.resolve()):
                    # Keep realistic asynchronous completion, independent of Internet jitter.
                    time.sleep(0.1)
                    body = path.read_bytes()
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                    return
            if payload is None:
                self.send_error(404)
                return
            body = json.dumps(payload, ensure_ascii=False).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"Serving local captured articles on 127.0.0.1:{port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["capture", "serve"])
    parser.add_argument("--directory", type=Path, default=Path("build/macos-real-reading"))
    parser.add_argument("--port", type=int, default=18764)
    parser.add_argument("--skip-images", action="store_true")
    options = parser.parse_args()
    if options.mode == "capture":
        capture(options.directory, include_images=not options.skip_images)
    else:
        serve(options.directory, options.port)
