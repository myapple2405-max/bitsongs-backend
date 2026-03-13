import json
import os
import secrets
import sqlite3
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any
from urllib.parse import quote

import requests
import yt_dlp
from fastapi import FastAPI, Form, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse, PlainTextResponse, RedirectResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from starlette.middleware.sessions import SessionMiddleware
from werkzeug.security import check_password_hash, generate_password_hash

from recommendation import (
    get_recommendations as get_song_recommendations,
    get_song_by_id,
    get_songs_by_ids,
    get_up_next,
    update_transition,
    upsert_song_records,
)


app = FastAPI()

# --- CONFIGURATION ---
SECRET_KEY = os.environ.get("FLASK_SECRET_KEY", secrets.token_hex(32))
IS_PRODUCTION = os.environ.get("FLASK_ENV") == "production"

app.add_middleware(
    SessionMiddleware,
    secret_key=SECRET_KEY,
    same_site="lax",
    https_only=IS_PRODUCTION,
    max_age=60 * 60 * 24 * 14,
)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["Content-Type", "Authorization"],
)

# --- PATHS ---
BASE_DIR = Path(__file__).resolve().parent
DATA_DIR = BASE_DIR / "data"
CACHE_DIR = BASE_DIR / "song_cache"
DB_NAME = DATA_DIR / "pymusic.db"
CACHE_LIMIT_BYTES = 600 * 1024 * 1024

DATA_DIR.mkdir(parents=True, exist_ok=True)
CACHE_DIR.mkdir(parents=True, exist_ok=True)

app.mount("/static", StaticFiles(directory=BASE_DIR / "static"), name="static")
templates = Jinja2Templates(directory=str(BASE_DIR / "templates"))

# Thread Pool for downloads
executor = ThreadPoolExecutor(max_workers=2)


@app.middleware("http")
async def security_headers_and_csrf(request: Request, call_next):
    if not request.url.path.startswith("/api/mobile/") and request.method == "POST":
        origin = request.headers.get("origin")
        referer = request.headers.get("referer")
        if origin or referer:
            target = origin or referer or ""
            if request.url.netloc not in target:
                return PlainTextResponse("Forbidden", status_code=403)

    response = await call_next(request)
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "SAMEORIGIN"
    response.headers["X-XSS-Protection"] = "1; mode=block"
    response.headers["Accept-Ranges"] = "bytes"
    return response


# --- DATABASE SETUP ---
def init_db() -> None:
    try:
        with sqlite3.connect(DB_NAME) as conn:
            c = conn.cursor()
            c.execute(
                """CREATE TABLE IF NOT EXISTS users
                        (id INTEGER PRIMARY KEY AUTOINCREMENT,
                        username TEXT UNIQUE NOT NULL, password TEXT NOT NULL, role TEXT NOT NULL)"""
            )
            c.execute(
                """CREATE TABLE IF NOT EXISTS likes
                        (user_id INTEGER, song_id TEXT, song_data TEXT,
                        timestamp DATETIME DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY (user_id, song_id))"""
            )
            c.execute("SELECT * FROM users WHERE username = ?", ("admin",))
            if not c.fetchone():
                hashed_pw = generate_password_hash("admin123")
                c.execute(
                    "INSERT INTO users (username, password, role) VALUES (?, ?, ?)",
                    ("admin", hashed_pw, "admin"),
                )
            conn.commit()
    except Exception as exc:
        print(f"Database initialization error: {exc}")


init_db()


def get_db_connection() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_NAME)
    conn.row_factory = sqlite3.Row
    return conn


def template_response(request: Request, name: str, **context: Any):
    context["request"] = request
    context["version"] = int(time.time())
    return templates.TemplateResponse(name, context)


# --- HELPER FUNCTIONS ---
def current_user_id(request: Request):
    return request.session.get("user_id")


def require_logged_in(request: Request):
    if not current_user_id(request):
        return PlainTextResponse("Unauthorized", status_code=401)
    return None


def require_admin(request: Request):
    if not current_user_id(request) or request.session.get("role") != "admin":
        return PlainTextResponse("Unauthorized", status_code=401)
    return None


def is_song_cached(song_id):
    return (CACHE_DIR / f"{song_id}.m4a").exists()


def get_cache_size_bytes():
    return sum(entry.stat().st_size for entry in CACHE_DIR.iterdir() if entry.is_file())


def clear_audio_cache():
    for entry in CACHE_DIR.iterdir():
        if entry.is_file():
            try:
                entry.unlink()
            except OSError:
                pass


def clear_cache_if_needed():
    if get_cache_size_bytes() > CACHE_LIMIT_BYTES:
        clear_audio_cache()


def inject_cache_status(songs):
    for song in songs:
        song["cached"] = is_song_cached(song["id"])
    return songs


def _itunes_to_song(item):
    art_url = item.get("artworkUrl100", "")
    cover = art_url.replace("100x100bb", "200x200bb") if art_url else ""
    cover_xl = art_url.replace("100x100bb", "600x600bb") if art_url else ""
    return {
        "id": str(item.get("trackId", item.get("collectionId", 0))),
        "title": item.get("trackName", "Unknown"),
        "artist": item.get("artistName", "Unknown"),
        "artist_id": item.get("artistId", 0),
        "album": item.get("collectionName", "Single"),
        "cover": cover,
        "cover_xl": cover_xl,
        "duration": item.get("trackTimeMillis", 0) // 1000,
        "genre": item.get("primaryGenreName", "Music"),
    }


def search_songs(query):
    if not query:
        return []
    try:
        response = requests.get(
            "https://itunes.apple.com/search",
            params={"term": query, "media": "music", "limit": 25, "country": "IN"},
            timeout=10,
        )
        data = response.json()
        songs = [_itunes_to_song(item) for item in data.get("results", []) if item.get("trackName")]
        upsert_song_records(songs)
        return inject_cache_status(songs)
    except Exception:
        return []


def get_chart():
    try:
        response = requests.get("https://itunes.apple.com/in/rss/topsongs/limit=25/json", timeout=10).json()
        entries = response.get("feed", {}).get("entry", [])
        songs = []
        for entry in entries:
            try:
                art_url = ""
                for img in entry.get("im:image", []):
                    art_url = img.get("label", "")
                cover = art_url.replace("170x170bb", "200x200bb") if art_url else ""
                cover_xl = art_url.replace("170x170bb", "600x600bb") if art_url else ""
                artist_id = 0
                artist_link = entry.get("im:artist", {}).get("attributes", {}).get("href", "")
                if "/id" in artist_link:
                    try:
                        artist_id = int(artist_link.split("/id")[-1].split("?")[0])
                    except Exception:
                        pass
                track_id = str(entry.get("id", {}).get("attributes", {}).get("im:id", "0") or "0")
                genre = entry.get("category", {}).get("attributes", {}).get("label", "Music")
                songs.append(
                    {
                        "id": track_id,
                        "title": entry.get("im:name", {}).get("label", "Unknown"),
                        "artist": entry.get("im:artist", {}).get("label", "Unknown"),
                        "artist_id": artist_id,
                        "album": entry.get("im:collection", {}).get("im:name", {}).get("label", "Single"),
                        "cover": cover,
                        "cover_xl": cover_xl,
                        "duration": 0,
                        "genre": genre,
                    }
                )
            except Exception:
                continue
        upsert_song_records(songs)
        return inject_cache_status(songs)
    except Exception:
        return []


def fetch_lyrics(artist, title):
    try:
        resp = requests.get(
            "https://lrclib.net/api/search",
            params={"artist_name": artist, "track_name": title},
            headers={"User-Agent": "PyMusic/1.0"},
            timeout=5,
        )
        data = resp.json()
        if isinstance(data, list) and data:
            for item in data:
                if item.get("syncedLyrics"):
                    return {"type": "synced", "text": item["syncedLyrics"]}
            for item in data:
                if item.get("plainLyrics"):
                    return {"type": "plain", "text": item["plainLyrics"]}
        return {"type": "error", "text": "No lyrics found."}
    except Exception:
        return {"type": "error", "text": "Lyrics unavailable."}


def fetch_artist_tracks(artist_id, limit=20):
    try:
        artist_id = int(artist_id or 0)
        if artist_id <= 0:
            return []
        response = requests.get(
            "https://itunes.apple.com/lookup",
            params={"id": artist_id, "entity": "song", "limit": limit, "country": "IN"},
            timeout=10,
        )
        data = response.json()
        songs = [_itunes_to_song(item) for item in data.get("results", []) if item.get("wrapperType") == "track" and item.get("trackName")]
        if songs:
            upsert_song_records(songs)
        return songs
    except Exception:
        return []


def fetch_artist_search_results(artist_name, limit=25):
    try:
        artist_name = (artist_name or "").strip()
        if not artist_name:
            return []
        response = requests.get(
            "https://itunes.apple.com/search",
            params={"term": artist_name, "media": "music", "entity": "song", "limit": limit, "country": "IN"},
            timeout=10,
        )
        data = response.json()
        songs = []
        normalized_artist = artist_name.casefold()
        for item in data.get("results", []):
            item_artist = str(item.get("artistName", "")).strip()
            if not item.get("trackName"):
                continue
            if normalized_artist not in item_artist.casefold() and item_artist.casefold() not in normalized_artist:
                continue
            songs.append(_itunes_to_song(item))
        if songs:
            upsert_song_records(songs)
        return songs
    except Exception:
        return []


def enrich_catalog_for_song(song_id):
    song = get_song_by_id(song_id)
    if not song:
        return
    fetched_songs = fetch_artist_tracks(song.get("artist_id"))
    if not fetched_songs:
        fetch_artist_search_results(song.get("artist"))


def hydrate_song_ids(song_ids):
    return inject_cache_status(get_songs_by_ids(song_ids))


def build_recommendation_response(song_id):
    enrich_catalog_for_song(song_id)
    grouped_ids = get_song_recommendations(song_id)
    return {
        "behavior_based": hydrate_song_ids(grouped_ids.get("behavior_based", [])),
        "content_based": hydrate_song_ids(grouped_ids.get("content_based", [])),
    }


def build_up_next_response(song_id, limit=10):
    enrich_catalog_for_song(song_id)
    entries = get_up_next(song_id, limit=limit)
    songs_by_id = {song["id"]: song for song in hydrate_song_ids([entry["song_id"] for entry in entries])}
    result = []
    for entry in entries:
        song = songs_by_id.get(entry["song_id"])
        if song:
            item = dict(song)
            item["reason"] = entry["reason"]
            result.append(item)
    return result


def download_task(song_id, artist, title):
    clear_cache_if_needed()
    filepath = CACHE_DIR / f"{song_id}.m4a"
    if filepath.exists():
        return
    query = f"{artist} - {title} audio"
    ydl_opts = {
        "format": "bestaudio[ext=m4a]/best",
        "outtmpl": str(filepath),
        "quiet": True,
        "noplaylist": True,
        "extractor_args": {"youtube": {"client": ["android", "ios"]}},
    }
    try:
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            ydl.download([f"ytsearch1:{query}"])
        clear_cache_if_needed()
    except Exception:
        pass


def build_proxy_response(url: str, incoming_headers, headers_json: str, chunk_size: int):
    try:
        try:
            yt_headers = json.loads(headers_json or "{}")
        except Exception:
            yt_headers = {}

        headers = {
            "User-Agent": yt_headers.get("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36"),
            "Accept": yt_headers.get("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"),
            "Accept-Language": yt_headers.get("Accept-Language", "en-us,en;q=0.5"),
            "Sec-Fetch-Mode": yt_headers.get("Sec-Fetch-Mode", "navigate"),
        }
        if "range" in incoming_headers:
            headers["Range"] = incoming_headers["range"]

        req = requests.get(url, stream=True, headers=headers, timeout=30)
        excluded_headers = {"content-encoding", "transfer-encoding", "connection"}
        response_headers = {name: value for name, value in req.headers.items() if name.lower() not in excluded_headers}
        response_headers["Accept-Ranges"] = "bytes"
        return StreamingResponse(req.iter_content(chunk_size=chunk_size), status_code=req.status_code, media_type=req.headers.get("content-type", "audio/mp4"), headers=response_headers)
    except Exception as exc:
        return PlainTextResponse(f"Stream error: {exc}", status_code=500)


def render_play_response(request: Request, song_id: str, artist: str, title: str, mobile: bool):
    filename = f"{song_id}.m4a"
    filepath = CACHE_DIR / filename
    if filepath.exists():
        if mobile:
            base_url = str(request.base_url).rstrip("/")
            return JSONResponse({"source": "local", "url": f"{base_url}/api/mobile/stream_cache/{filename}"})
        return JSONResponse({"source": "local", "url": str(request.url_for("stream_cache_file", filename=filename))})

    query = f"{artist} - {title} audio"
    ydl_opts = {
        "format": "bestaudio[ext=m4a]/bestaudio/best",
        "quiet": True,
        "noplaylist": True,
        "extractor_args": {"youtube": {"client": ["android", "ios"]}},
    }
    with yt_dlp.YoutubeDL(ydl_opts) as ydl:
        try:
            info = ydl.extract_info(f"ytsearch1:{query}", download=False)
            video = info["entries"][0] if "entries" in info else info
            http_headers = video.get("http_headers", {})
            if mobile:
                base_url = str(request.base_url).rstrip("/")
                proxy_url = f"{base_url}/api/mobile/stream_proxy?url={quote(video['url'])}&headers={quote(json.dumps(http_headers))}"
                return JSONResponse({"source": "youtube", "url": proxy_url, "direct_url": video["url"], "headers": http_headers})
            return JSONResponse({"source": "youtube", "url": video["url"], "headers": http_headers})
        except Exception as exc:
            return JSONResponse({"error": f"Song not found: {exc}" if mobile else "Not found"}, status_code=404)


# --- AUTHENTICATED CACHE ROUTES ---
@app.post("/api/cache_song")
async def cache_song(request: Request):
    unauthorized = require_logged_in(request)
    if unauthorized:
        return unauthorized
    data = await request.json()
    executor.submit(download_task, str(data.get("id")), data.get("artist"), data.get("title"))
    return JSONResponse({"status": "queued"})


@app.get("/stream_cache/{filename:path}", name="stream_cache_file")
def stream_cache_file(request: Request, filename: str):
    unauthorized = require_logged_in(request)
    if unauthorized:
        return unauthorized
    filepath = CACHE_DIR / filename
    if not filepath.exists():
        return PlainTextResponse("Not Found", status_code=404)
    return FileResponse(filepath)


@app.get("/play")
def play(request: Request, id: str = "", artist: str = "", title: str = "", previous_song_id: str | None = None):
    unauthorized = require_logged_in(request)
    if unauthorized:
        return unauthorized
    update_transition(previous_song_id, id)
    return render_play_response(request, id, artist, title, mobile=False)


# --- MOBILE API ---
@app.get("/api/mobile/search")
def mobile_search(q: str = ""):
    return JSONResponse(search_songs(q))


@app.get("/api/mobile/chart")
def mobile_chart():
    return JSONResponse(get_chart())


@app.get("/api/mobile/recommend")
def mobile_recommend(song_id: str = ""):
    return JSONResponse(build_recommendation_response(song_id))


@app.get("/api/mobile/up_next")
def mobile_up_next(song_id: str = "", limit: int = 10):
    return JSONResponse(build_up_next_response(song_id, limit=limit or 10))


@app.get("/api/mobile/lyrics")
def mobile_lyrics(artist: str = "", title: str = ""):
    return JSONResponse(fetch_lyrics(artist, title))


@app.get("/api/mobile/play")
def mobile_play(request: Request, id: str = "", artist: str = "", title: str = "", previous_song_id: str | None = None):
    update_transition(previous_song_id, id)
    return render_play_response(request, id, artist, title, mobile=True)


@app.get("/api/mobile/stream_cache/{filename:path}")
def mobile_stream_cache(filename: str):
    filepath = CACHE_DIR / filename
    if not filepath.exists():
        return PlainTextResponse("Not Found", status_code=404)
    return FileResponse(filepath)


@app.get("/api/mobile/stream_proxy")
def mobile_stream_proxy(request: Request, url: str = "", headers: str = "{}"):
    if not url:
        return PlainTextResponse("No URL", status_code=400)
    return build_proxy_response(url, request.headers, headers, chunk_size=1024 * 16)


@app.post("/api/mobile/cache_song")
async def mobile_cache_song(request: Request):
    data = await request.json()
    if not data:
        return JSONResponse({"error": "No data"}, status_code=400)
    executor.submit(download_task, str(data.get("id")), data.get("artist"), data.get("title"))
    return JSONResponse({"status": "queued"})


@app.get("/api/mobile/health")
def mobile_health():
    return JSONResponse({"status": "ok", "server": "PyMusic", "version": "2.0", "timestamp": int(time.time())})


# --- ADMIN ---
@app.post("/api/admin/cache_all")
def admin_cache_all(request: Request):
    unauthorized = require_admin(request)
    if unauthorized:
        return unauthorized
    conn = get_db_connection()
    rows = conn.execute("SELECT DISTINCT song_id, song_data FROM likes").fetchall()
    conn.close()
    count = 0
    for row in rows:
        try:
            data = json.loads(row["song_data"])
            executor.submit(download_task, str(data["id"]), data["artist"], data["title"])
            count += 1
        except Exception:
            continue
    return JSONResponse({"status": "started", "count": count})


@app.get("/api/admin/cache_stats")
def admin_cache_stats(request: Request):
    unauthorized = require_admin(request)
    if unauthorized:
        return unauthorized
    files = [f for f in CACHE_DIR.iterdir() if f.is_file() and f.suffix == ".m4a"]
    return JSONResponse({"count": len(files)})


@app.get("/admin")
def admin_panel(request: Request):
    if not current_user_id(request) or request.session.get("role") != "admin":
        return RedirectResponse(url="/", status_code=303)
    conn = get_db_connection()
    users = conn.execute("SELECT id, username, role FROM users").fetchall()
    conn.close()
    return template_response(request, "admin.html", users=users, current_user_id=request.session.get("user_id"))


@app.post("/add_user")
def add_user(request: Request, username: str = Form(...), password: str = Form(...), role: str = Form("user")):
    unauthorized = require_admin(request)
    if unauthorized:
        return unauthorized
    hashed = generate_password_hash(password)
    try:
        conn = get_db_connection()
        conn.execute("INSERT INTO users (username, password, role) VALUES (?, ?, ?)", (username, hashed, role))
        conn.commit()
        conn.close()
    except Exception:
        return PlainTextResponse("Error", status_code=400)
    return RedirectResponse(url="/admin", status_code=303)


@app.get("/delete_user/{uid}")
def delete_user(request: Request, uid: int):
    unauthorized = require_admin(request)
    if unauthorized:
        return unauthorized
    if uid == request.session["user_id"]:
        return PlainTextResponse("Error", status_code=400)
    conn = get_db_connection()
    conn.execute("DELETE FROM users WHERE id = ?", (uid,))
    conn.commit()
    conn.close()
    return RedirectResponse(url="/admin", status_code=303)


# --- USER ---
@app.post("/api/toggle_like")
async def toggle_like(request: Request):
    unauthorized = require_logged_in(request)
    if unauthorized:
        return unauthorized
    data = await request.json()
    song = data.get("song")
    if not song:
        return PlainTextResponse("No song data", status_code=400)
    song_id = str(song["id"])
    user_id = request.session["user_id"]
    conn = get_db_connection()
    exists = conn.execute("SELECT * FROM likes WHERE user_id = ? AND song_id = ?", (user_id, song_id)).fetchone()
    if exists:
        conn.execute("DELETE FROM likes WHERE user_id = ? AND song_id = ?", (user_id, song_id))
        action = "unliked"
    else:
        conn.execute("INSERT INTO likes (user_id, song_id, song_data) VALUES (?, ?, ?)", (user_id, song_id, json.dumps(song)))
        action = "liked"
    conn.commit()
    conn.close()
    return JSONResponse({"status": "success", "action": action})


@app.get("/api/likes")
def get_likes(request: Request):
    if not current_user_id(request):
        return JSONResponse([])
    conn = get_db_connection()
    rows = conn.execute("SELECT song_data FROM likes WHERE user_id = ? ORDER BY timestamp DESC", (request.session["user_id"],)).fetchall()
    conn.close()
    songs = []
    for row in rows:
        try:
            songs.append(json.loads(row["song_data"]))
        except Exception:
            continue
    return JSONResponse(inject_cache_status(songs))


@app.get("/login")
def login_page(request: Request):
    return template_response(request, "login.html", error=None)


@app.post("/login")
def login_submit(request: Request, username: str = Form(...), password: str = Form(...)):
    conn = get_db_connection()
    user = conn.execute("SELECT * FROM users WHERE username = ?", (username,)).fetchone()
    conn.close()
    if user and check_password_hash(user["password"], password):
        request.session["user_id"] = user["id"]
        request.session["username"] = user["username"]
        request.session["role"] = user["role"]
        return RedirectResponse(url="/", status_code=303)
    return template_response(request, "login.html", error="Invalid Credentials")


@app.get("/logout")
def logout(request: Request):
    request.session.clear()
    return RedirectResponse(url="/login", status_code=303)


@app.get("/")
def index(request: Request):
    if not current_user_id(request):
        return RedirectResponse(url="/login", status_code=303)
    return template_response(request, "index.html", username=request.session["username"], role=request.session["role"])


@app.get("/search")
def search(q: str = ""):
    return JSONResponse(search_songs(q))


@app.get("/chart")
def chart():
    return JSONResponse(get_chart())


@app.get("/recommend")
def recommend(song_id: str = ""):
    return JSONResponse(build_recommendation_response(song_id))


@app.get("/up_next")
def up_next(song_id: str = "", limit: int = 10):
    return JSONResponse(build_up_next_response(song_id, limit=limit or 10))


@app.get("/lyrics")
def lyrics(artist: str = "", title: str = ""):
    return JSONResponse(fetch_lyrics(artist, title))


@app.get("/stream_proxy")
def stream_proxy(request: Request, url: str = "", headers: str = "{}"):
    unauthorized = require_logged_in(request)
    if unauthorized:
        return unauthorized
    if not url:
        return PlainTextResponse("No URL", status_code=400)
    return build_proxy_response(url, request.headers, headers, chunk_size=1024 * 8)


if __name__ == "__main__":
    import uvicorn

    uvicorn.run("app:app", host="0.0.0.0", port=499, reload=False)
