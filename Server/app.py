import os
import secrets
import threading
from concurrent.futures import ThreadPoolExecutor
from urllib.parse import urlparse
from flask import Flask, render_template, request, jsonify, Response, stream_with_context, session, redirect, url_for, abort, send_from_directory
import yt_dlp
import requests
import sqlite3
import random
import json
import re
import time
from werkzeug.security import generate_password_hash, check_password_hash

app = Flask(__name__)

# --- CONFIGURATION ---
app.secret_key = os.environ.get("FLASK_SECRET_KEY", secrets.token_hex(32))
app.config['SESSION_COOKIE_SAMESITE'] = 'Lax'
app.config['SESSION_COOKIE_HTTPONLY'] = True
app.config['SESSION_COOKIE_SECURE'] = os.environ.get("FLASK_ENV") == "production"

# --- DOCKER PATHS ---
DATA_DIR = "data"
CACHE_DIR = "song_cache"

# Create folders if they don't exist (Crucial for Docker)
if not os.path.exists(DATA_DIR):
    os.makedirs(DATA_DIR)
if not os.path.exists(CACHE_DIR):
    os.makedirs(CACHE_DIR)

# Save DB inside the data folder
DB_NAME = os.path.join(DATA_DIR, "pymusic.db")

# Thread Pool for downloads
executor = ThreadPoolExecutor(max_workers=2)

if not os.path.exists(CACHE_DIR):
    os.makedirs(CACHE_DIR)

# --- CONTEXT PROCESSOR (Cache Buster) ---
@app.context_processor
def inject_version():
    return dict(version=int(time.time()))

# --- CORS for Mobile ---
@app.after_request
def add_headers(response):
    # Security headers
    response.headers['X-Content-Type-Options'] = 'nosniff'
    response.headers['X-Frame-Options'] = 'SAMEORIGIN'
    response.headers['X-XSS-Protection'] = '1; mode=block'
    response.headers['Accept-Ranges'] = 'bytes'
    # CORS headers for mobile app
    response.headers['Access-Control-Allow-Origin'] = '*'
    response.headers['Access-Control-Allow-Methods'] = 'GET, POST, OPTIONS'
    response.headers['Access-Control-Allow-Headers'] = 'Content-Type, Authorization'
    return response

# --- CSRF PROTECTION (skip for mobile API) ---
@app.before_request
def csrf_protect():
    # Skip CSRF for mobile API endpoints and OPTIONS requests
    if request.path.startswith('/api/mobile/') or request.method == 'OPTIONS':
        return
    if request.method == "POST":
        referer = request.headers.get('Referer')
        origin = request.headers.get('Origin')
        if not origin and not referer: return 
        target = origin if origin else referer
        if target and request.host not in target: return abort(403)

# --- DATABASE SETUP ---
def init_db():
    try:
        with sqlite3.connect(DB_NAME) as conn:
            c = conn.cursor()
            c.execute('''CREATE TABLE IF NOT EXISTS users 
                        (id INTEGER PRIMARY KEY AUTOINCREMENT, 
                        username TEXT UNIQUE NOT NULL, password TEXT NOT NULL, role TEXT NOT NULL)''')
            c.execute('''CREATE TABLE IF NOT EXISTS likes 
                        (user_id INTEGER, song_id TEXT, song_data TEXT, 
                        timestamp DATETIME DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY (user_id, song_id))''')
            c.execute("SELECT * FROM users WHERE username = ?", ('admin',))
            if not c.fetchone():
                hashed_pw = generate_password_hash("admin123") 
                c.execute("INSERT INTO users (username, password, role) VALUES (?, ?, ?)", ('admin', hashed_pw, 'admin'))
            conn.commit()
    except Exception as e: print(f"Database initialization error: {e}")

init_db()

def get_db_connection():
    conn = sqlite3.connect(DB_NAME)
    conn.row_factory = sqlite3.Row
    return conn

# --- HELPER FUNCTIONS ---
def is_song_cached(song_id):
    return os.path.exists(os.path.join(CACHE_DIR, f"{song_id}.m4a"))

def inject_cache_status(songs):
    for song in songs:
        song['cached'] = is_song_cached(song['id'])
    return songs

def _itunes_to_song(item):
    """Convert an iTunes API result item to our song format."""
    art_url = item.get('artworkUrl100', '')
    cover = art_url.replace('100x100bb', '200x200bb') if art_url else ''
    cover_xl = art_url.replace('100x100bb', '600x600bb') if art_url else ''
    return {
        'id': str(item.get('trackId', item.get('collectionId', 0))),
        'title': item.get('trackName', 'Unknown'),
        'artist': item.get('artistName', 'Unknown'),
        'artist_id': item.get('artistId', 0),
        'album': item.get('collectionName', 'Single'),
        'cover': cover,
        'cover_xl': cover_xl,
        'duration': item.get('trackTimeMillis', 0) // 1000,
        'genre': item.get('primaryGenreName', 'Music')
    }

def search_songs(query):
    if not query: return []
    try:
        response = requests.get("https://itunes.apple.com/search", 
                               params={'term': query, 'media': 'music', 'limit': 25, 'country': 'IN'},
                               timeout=10)
        data = response.json()
        songs = [_itunes_to_song(item) for item in data.get('results', []) if item.get('trackName')]
        return inject_cache_status(songs)
    except: return []

def get_chart():
    try:
        # Use iTunes RSS feed for top songs (India)
        url = "https://itunes.apple.com/in/rss/topsongs/limit=25/json"
        response = requests.get(url, timeout=10).json()
        entries = response.get('feed', {}).get('entry', [])
        songs = []
        for entry in entries:
            try:
                art_url = ''
                for img in entry.get('im:image', []):
                    art_url = img.get('label', '')
                cover = art_url.replace('170x170bb', '200x200bb') if art_url else ''
                cover_xl = art_url.replace('170x170bb', '600x600bb') if art_url else ''
                
                # Extract artist ID from artist link
                artist_id = 0
                artist_link = entry.get('im:artist', {}).get('attributes', {}).get('href', '')
                if '/id' in artist_link:
                    try: artist_id = int(artist_link.split('/id')[-1].split('?')[0])
                    except: pass
                
                # Extract track ID from id attributes
                track_id = '0'
                id_attrs = entry.get('id', {}).get('attributes', {}).get('im:id', '0')
                if id_attrs: track_id = str(id_attrs)
                
                # Extract genre
                genre = entry.get('category', {}).get('attributes', {}).get('label', 'Music')
                
                songs.append({
                    'id': track_id,
                    'title': entry.get('im:name', {}).get('label', 'Unknown'),
                    'artist': entry.get('im:artist', {}).get('label', 'Unknown'),
                    'artist_id': artist_id,
                    'album': entry.get('im:collection', {}).get('im:name', {}).get('label', 'Single'),
                    'cover': cover,
                    'cover_xl': cover_xl,
                    'duration': 0,
                    'genre': genre
                })
            except: continue
        return inject_cache_status(songs)
    except: return []

def get_recommendations(artist_id):
    try:
        if not artist_id: return []
        # Use iTunes lookup to get the artist name, then search for similar music
        lookup_url = f"https://itunes.apple.com/lookup?id={artist_id}&entity=song&limit=15&country=IN"
        response = requests.get(lookup_url, timeout=10).json()
        results = response.get('results', [])
        songs = []
        for item in results:
            if item.get('wrapperType') == 'track' and item.get('trackName'):
                songs.append(_itunes_to_song(item))
        random.shuffle(songs)
        return inject_cache_status(songs[:15])
    except: return []

def fetch_lyrics(artist, title):
    try:
        resp = requests.get("https://lrclib.net/api/search", 
                           params={'artist_name': artist, 'track_name': title}, 
                           headers={'User-Agent': 'PyMusic/1.0'}, timeout=5)
        data = resp.json()
        if isinstance(data, list) and len(data) > 0:
            for item in data:
                if item.get('syncedLyrics'): return {'type': 'synced', 'text': item['syncedLyrics']}
            for item in data:
                if item.get('plainLyrics'): return {'type': 'plain', 'text': item['plainLyrics']}
        return {'type': 'error', 'text': "No lyrics found."}
    except: return {'type': 'error', 'text': "Lyrics unavailable."}

# --- CACHING ---
def download_task(song_id, artist, title):
    filename = f"{song_id}.m4a"
    filepath = os.path.join(CACHE_DIR, filename)
    if os.path.exists(filepath): return
    query = f"{artist} - {title} audio"
    ydl_opts = {
        'format': 'bestaudio[ext=m4a]/best', 
        'outtmpl': filepath, 
        'quiet': True, 
        'noplaylist': True,
        'extractor_args': {'youtube': {'client': ['android', 'ios']}}
    }
    try:
        with yt_dlp.YoutubeDL(ydl_opts) as ydl: ydl.download([f"ytsearch1:{query}"])
    except: pass

@app.route('/api/cache_song', methods=['POST'])
def cache_song():
    if not session.get('user_id'): return "Unauthorized", 401
    data = request.json
    executor.submit(download_task, str(data.get('id')), data.get('artist'), data.get('title'))
    return jsonify({"status": "queued"})

@app.route('/stream_cache/<path:filename>')
def stream_cache_file(filename):
    if not session.get('user_id'): return "Unauthorized", 401
    return send_from_directory(CACHE_DIR, filename)

@app.route('/play')
def play():
    if not session.get('user_id'): return jsonify({'error': 'Unauthorized'}), 401
    artist = request.args.get('artist')
    title = request.args.get('title')
    song_id = request.args.get('id') 
    filename = f"{song_id}.m4a"
    if os.path.exists(os.path.join(CACHE_DIR, filename)):
        return jsonify({'source': 'local', 'url': url_for('stream_cache_file', filename=filename)})
    query = f"{artist} - {title} audio"
    ydl_opts = {
        'format': 'bestaudio[ext=m4a]/bestaudio/best', 
        'quiet': True, 
        'noplaylist': True,
        'extractor_args': {'youtube': {'client': ['android', 'ios']}}
    }
    with yt_dlp.YoutubeDL(ydl_opts) as ydl:
        try:
            info = ydl.extract_info(f"ytsearch1:{query}", download=False)
            video = info['entries'][0] if 'entries' in info else info
            http_headers = video.get('http_headers', {})
            return jsonify({'source': 'youtube', 'url': video['url'], 'headers': http_headers})
        except: return jsonify({'error': 'Not found'}), 404

# ============================================================
# === MOBILE API ENDPOINTS (No session auth required) ========
# ============================================================

@app.route('/api/mobile/search')
def mobile_search():
    """Search songs via iTunes API - returns JSON array of songs"""
    query = request.args.get('q', '')
    songs = search_songs(query)
    return jsonify(songs)

@app.route('/api/mobile/chart')
def mobile_chart():
    """Get trending/chart songs - returns JSON array of songs"""
    songs = get_chart()
    return jsonify(songs)

@app.route('/api/mobile/recommend')
def mobile_recommend():
    """Get recommendations based on artist - returns JSON array of songs"""
    artist_id = request.args.get('artist_id', '')
    songs = get_recommendations(artist_id)
    return jsonify(songs)

@app.route('/api/mobile/lyrics')
def mobile_lyrics():
    """Get song lyrics - returns { type, text }"""
    artist = request.args.get('artist', '')
    title = request.args.get('title', '')
    result = fetch_lyrics(artist, title)
    return jsonify(result)

@app.route('/api/mobile/play')
def mobile_play():
    """Get stream URL for a song - returns { source, url, headers }"""
    artist = request.args.get('artist', '')
    title = request.args.get('title', '')
    song_id = request.args.get('id', '')
    
    # Check cache first
    filename = f"{song_id}.m4a"
    if os.path.exists(os.path.join(CACHE_DIR, filename)):
        # Serve from local cache
        base_url = request.host_url.rstrip('/')
        return jsonify({
            'source': 'local',
            'url': f"{base_url}/api/mobile/stream_cache/{filename}"
        })
    
    # Search YouTube for the audio
    query = f"{artist} - {title} audio"
    ydl_opts = {
        'format': 'bestaudio[ext=m4a]/bestaudio/best', 
        'quiet': True, 
        'noplaylist': True,
        'extractor_args': {'youtube': {'client': ['android', 'ios']}}
    }
    with yt_dlp.YoutubeDL(ydl_opts) as ydl:
        try:
            info = ydl.extract_info(f"ytsearch1:{query}", download=False)
            video = info['entries'][0] if 'entries' in info else info
            http_headers = video.get('http_headers', {})
            stream_url = video['url']
            
            # Return a proxy URL so the iOS app can stream through our server
            # (YouTube URLs have short TTLs and require specific headers)
            import urllib.parse
            base_url = request.host_url.rstrip('/')
            proxy_url = f"{base_url}/api/mobile/stream_proxy?url={urllib.parse.quote(stream_url)}&headers={urllib.parse.quote(json.dumps(http_headers))}"
            
            return jsonify({
                'source': 'youtube',
                'url': proxy_url,
                'direct_url': stream_url,
                'headers': http_headers
            })
        except Exception as e:
            return jsonify({'error': f'Song not found: {str(e)}'}), 404

@app.route('/api/mobile/stream_cache/<path:filename>')
def mobile_stream_cache(filename):
    """Serve cached audio files for mobile"""
    return send_from_directory(CACHE_DIR, filename)

@app.route('/api/mobile/stream_proxy')
def mobile_stream_proxy():
    """Proxy audio stream to mobile app, handles YouTube headers"""
    url = request.args.get('url')
    if not url:
        return "No URL", 400
    try:
        yt_headers_json = request.args.get('headers', '{}')
        try: yt_headers = json.loads(yt_headers_json)
        except: yt_headers = {}
        
        headers = {
            'User-Agent': yt_headers.get('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36'),
            'Accept': yt_headers.get('Accept', 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'),
            'Accept-Language': yt_headers.get('Accept-Language', 'en-us,en;q=0.5'),
            'Sec-Fetch-Mode': yt_headers.get('Sec-Fetch-Mode', 'navigate'),
        }
        
        # Handle Range requests (critical for iOS AVPlayer seeking)
        if 'Range' in request.headers:
            headers['Range'] = request.headers['Range']
        
        req = requests.get(url, stream=True, headers=headers, timeout=30)
        excluded_headers = ['content-encoding', 'transfer-encoding', 'connection']
        response_headers = [(name, value) for (name, value) in req.headers.items() if name.lower() not in excluded_headers]
        
        # Add headers iOS AVPlayer needs
        response_headers.append(('Accept-Ranges', 'bytes'))
        
        return Response(
            stream_with_context(req.iter_content(chunk_size=1024*16)),
            status=req.status_code,
            headers=response_headers,
            content_type=req.headers.get('content-type', 'audio/mp4')
        )
    except Exception as e:
        return f"Stream error: {e}", 500

@app.route('/api/mobile/cache_song', methods=['POST'])
def mobile_cache_song():
    """Pre-cache a song for faster playback"""
    data = request.json
    if not data:
        return jsonify({"error": "No data"}), 400
    executor.submit(download_task, str(data.get('id')), data.get('artist'), data.get('title'))
    return jsonify({"status": "queued"})

@app.route('/api/mobile/health')
def mobile_health():
    """Health check endpoint for the mobile app"""
    return jsonify({
        "status": "ok",
        "server": "PyMusic",
        "version": "2.0",
        "timestamp": int(time.time())
    })

# ============================================================
# === EXISTING WEB ROUTES (unchanged) ========================
# ============================================================

# --- ADMIN ---
@app.route('/api/admin/cache_all', methods=['POST'])
def admin_cache_all():
    if not session.get('user_id') or session.get('role') != 'admin': return "Unauthorized", 401
    conn = get_db_connection()
    rows = conn.execute("SELECT DISTINCT song_id, song_data FROM likes").fetchall()
    conn.close()
    count = 0
    for row in rows:
        try:
            data = json.loads(row['song_data'])
            executor.submit(download_task, str(data['id']), data['artist'], data['title'])
            count += 1
        except: continue
    return jsonify({"status": "started", "count": count})

@app.route('/api/admin/cache_stats')
def admin_cache_stats():
    if not session.get('user_id') or session.get('role') != 'admin': return "Unauthorized", 401
    files = [f for f in os.listdir(CACHE_DIR) if f.endswith('.m4a')]
    return jsonify({"count": len(files)})

@app.route('/admin')
def admin_panel():
    if not session.get('user_id') or session.get('role') != 'admin': return redirect(url_for('index'))
    conn = get_db_connection()
    users = conn.execute('SELECT id, username, role FROM users').fetchall()
    conn.close()
    return render_template('admin.html', users=users)

@app.route('/add_user', methods=['POST'])
def add_user():
    if not session.get('user_id') or session.get('role') != 'admin': return "Unauthorized", 401
    username = request.form.get('username')
    password = request.form.get('password')
    role = request.form.get('role', 'user')
    hashed = generate_password_hash(password)
    try:
        conn = get_db_connection()
        conn.execute("INSERT INTO users (username, password, role) VALUES (?, ?, ?)", (username, hashed, role))
        conn.commit()
        conn.close()
    except: return "Error", 400
    return redirect(url_for('admin_panel'))

@app.route('/delete_user/<int:uid>')
def delete_user(uid):
    if not session.get('user_id') or session.get('role') != 'admin': return "Unauthorized", 401
    if uid == session['user_id']: return "Error", 400
    conn = get_db_connection()
    conn.execute('DELETE FROM users WHERE id = ?', (uid,))
    conn.commit()
    conn.close()
    return redirect(url_for('admin_panel'))

# --- USER ---
@app.route('/api/toggle_like', methods=['POST'])
def toggle_like():
    if not session.get('user_id'): return "Unauthorized", 401
    data = request.json
    song = data.get('song')
    if not song: return "No song data", 400
    song_id = str(song['id'])
    user_id = session['user_id']
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
    return jsonify({"status": "success", "action": action})

@app.route('/api/likes')
def get_likes():
    if not session.get('user_id'): return jsonify([])
    conn = get_db_connection()
    rows = conn.execute("SELECT song_data FROM likes WHERE user_id = ? ORDER BY timestamp DESC", (session['user_id'],)).fetchall()
    conn.close()
    songs = []
    for row in rows:
        try: songs.append(json.loads(row['song_data']))
        except: continue
    return jsonify(inject_cache_status(songs))

@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        username = request.form.get('username')
        password = request.form.get('password')
        conn = get_db_connection()
        user = conn.execute('SELECT * FROM users WHERE username = ?', (username,)).fetchone()
        conn.close()
        if user and check_password_hash(user['password'], password):
            session['user_id'] = user['id']
            session['username'] = user['username']
            session['role'] = user['role']
            session.permanent = True
            return redirect(url_for('index'))
        else: return render_template('login.html', error="Invalid Credentials")
    return render_template('login.html')

@app.route('/logout')
def logout(): session.clear(); return redirect(url_for('login'))

@app.route('/')
def index():
    if not session.get('user_id'): return redirect(url_for('login'))
    return render_template('index.html', username=session['username'], role=session['role'])

@app.route('/search')
def search(): return jsonify(search_songs(request.args.get('q')))

@app.route('/chart')
def chart(): return jsonify(get_chart())

@app.route('/recommend')
def recommend(): return jsonify(get_recommendations(request.args.get('artist_id')))

@app.route('/lyrics')
def lyrics(): return jsonify(fetch_lyrics(request.args.get('artist'), request.args.get('title')))

@app.route('/stream_proxy')
def stream_proxy():
    if not session.get('user_id'): return "Unauthorized", 401
    url = request.args.get('url')
    if not url: return "No URL", 400
    try:
        # Use yt-dlp headers passed from the frontend, or sensible defaults
        yt_headers_json = request.args.get('headers', '{}')
        try: yt_headers = json.loads(yt_headers_json)
        except: yt_headers = {}
        
        headers = {
            'User-Agent': yt_headers.get('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36'),
            'Accept': yt_headers.get('Accept', 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'),
            'Accept-Language': yt_headers.get('Accept-Language', 'en-us,en;q=0.5'),
            'Sec-Fetch-Mode': yt_headers.get('Sec-Fetch-Mode', 'navigate'),
        }
        if 'Range' in request.headers: headers['Range'] = request.headers['Range']
        req = requests.get(url, stream=True, headers=headers, timeout=30)
        excluded_headers = ['content-encoding', 'transfer-encoding', 'connection']
        headers_response = [(name, value) for (name, value) in req.headers.items() if name.lower() not in excluded_headers]
        return Response(stream_with_context(req.iter_content(chunk_size=1024*8)), status=req.status_code, headers=headers_response, content_type=req.headers.get('content-type'))
    except Exception as e: return f"Error: {e}", 500
if __name__ == '__main__':
    app.run(host='0.0.0.0', debug=False, port=499)
