"""
Bookstore API — backed entirely by Valkey (no relational DB).

Data model in Valkey:
  book:{isbn}         → Hash   { isbn, title, author, year, price, description }
  books               → Set    of all ISBNs (index for listing)
  books:author:{name} → Set    of ISBNs by author (secondary index)
"""

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field
from typing import Optional, List
import valkey
from valkey.sentinel import Sentinel
import os
import logging

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(
    title="Bookstore API",
    description="Simple bookstore REST API — Valkey is the only datastore.",
    version="1.0.0",
)

VALKEY_HOST = os.getenv("VALKEY_HOST", "valkey")
VALKEY_PORT = int(os.getenv("VALKEY_PORT", "6379"))
VALKEY_PASSWORD = os.getenv("VALKEY_PASSWORD", None)

VALKEY_SENTINEL_ENABLED = os.getenv("VALKEY_SENTINEL_ENABLED", "false").lower() == "true"
VALKEY_SENTINEL_HOSTS = os.getenv("VALKEY_SENTINEL_HOSTS", f"{VALKEY_HOST}:26379")
VALKEY_SENTINEL_MASTER_NAME = os.getenv("VALKEY_SENTINEL_MASTER_NAME", "mymaster")

VALKEY_TLS_ENABLED = os.getenv("VALKEY_TLS_ENABLED", "false").lower() == "true"
VALKEY_TLS_CA_CERT = os.getenv("VALKEY_TLS_CA_CERT", "/certs/ca.crt")

_sentinel: Optional[Sentinel] = None


def _tls_kwargs() -> dict:
    if not VALKEY_TLS_ENABLED:
        return {}
    return {"ssl": True, "ssl_ca_certs": VALKEY_TLS_CA_CERT}


def _get_sentinel() -> Sentinel:
    global _sentinel
    if _sentinel is None:
        hosts = [
            (h.rsplit(":", 1)[0], int(h.rsplit(":", 1)[1]))
            for h in VALKEY_SENTINEL_HOSTS.split(",")
        ]
        logger.info(
            "Connecting via Sentinel: master=%s hosts=%s tls=%s",
            VALKEY_SENTINEL_MASTER_NAME, hosts, VALKEY_TLS_ENABLED,
        )
        _sentinel = Sentinel(
            hosts,
            socket_connect_timeout=3,
            sentinel_kwargs={"password": VALKEY_PASSWORD or None, **_tls_kwargs()},
            password=VALKEY_PASSWORD or None,
            **_tls_kwargs(),
        )
    return _sentinel


def get_client() -> valkey.Valkey:
    if VALKEY_SENTINEL_ENABLED:
        return _get_sentinel().master_for(
            VALKEY_SENTINEL_MASTER_NAME,
            password=VALKEY_PASSWORD or None,
            decode_responses=True,
            socket_connect_timeout=3,
            **_tls_kwargs(),
        )
    return valkey.Valkey(
        host=VALKEY_HOST,
        port=VALKEY_PORT,
        password=VALKEY_PASSWORD or None,
        decode_responses=True,
        socket_connect_timeout=3,
        **_tls_kwargs(),
    )


# ── Models ────────────────────────────────────────────────────────────────────

class Book(BaseModel):
    isbn: str = Field(..., description="ISBN-13, used as the unique key")
    title: str
    author: str
    year: int = Field(..., ge=0, le=2100)
    price: float = Field(..., ge=0)
    description: Optional[str] = ""


class BookUpdate(BaseModel):
    title: Optional[str] = None
    author: Optional[str] = None
    year: Optional[int] = Field(default=None, ge=0, le=2100)
    price: Optional[float] = Field(default=None, ge=0)
    description: Optional[str] = None


# ── Helpers ───────────────────────────────────────────────────────────────────

def _book_key(isbn: str) -> str:
    return f"book:{isbn}"


def _hash_to_book(data: dict) -> dict:
    """Coerce Valkey Hash strings back to proper types."""
    if not data:
        return data
    if "year" in data:
        data["year"] = int(data["year"])
    if "price" in data:
        data["price"] = float(data["price"])
    return data


# ── Routes ────────────────────────────────────────────────────────────────────

@app.get("/health", tags=["ops"])
def health():
    """Liveness / readiness probe — also verifies Valkey connectivity."""
    try:
        r = get_client()
        r.ping()
        book_count = r.scard("books")
        if VALKEY_SENTINEL_ENABLED:
            connection = f"sentinel://{VALKEY_SENTINEL_HOSTS} master={VALKEY_SENTINEL_MASTER_NAME}"
        else:
            connection = f"{VALKEY_HOST}:{VALKEY_PORT}"
        return {
            "status": "ok",
            "valkey": connection,
            "sentinel": VALKEY_SENTINEL_ENABLED,
            "tls": VALKEY_TLS_ENABLED,
            "books_in_store": book_count,
        }
    except Exception as exc:
        logger.error("Valkey ping failed: %s", exc)
        raise HTTPException(status_code=503, detail=f"Valkey unreachable: {exc}")


@app.get("/books", response_model=List[dict], tags=["books"])
def list_books():
    """Return all books (unordered)."""
    r = get_client()
    isbns = r.smembers("books")
    pipe = r.pipeline()
    for isbn in isbns:
        pipe.hgetall(_book_key(isbn))
    results = pipe.execute()
    return [_hash_to_book(b) for b in results if b]


@app.get("/books/{isbn}", tags=["books"])
def get_book(isbn: str):
    """Return a single book by ISBN."""
    r = get_client()
    data = r.hgetall(_book_key(isbn))
    if not data:
        raise HTTPException(status_code=404, detail=f"Book '{isbn}' not found")
    return _hash_to_book(data)


@app.post("/books", status_code=201, tags=["books"])
def create_book(book: Book):
    """Create a new book. ISBN must be unique."""
    r = get_client()
    key = _book_key(book.isbn)
    if r.exists(key):
        raise HTTPException(
            status_code=409, detail=f"Book with ISBN '{book.isbn}' already exists"
        )
    mapping = {
        "isbn": book.isbn,
        "title": book.title,
        "author": book.author,
        "year": str(book.year),
        "price": str(book.price),
        "description": book.description or "",
    }
    pipe = r.pipeline()
    pipe.hset(key, mapping=mapping)
    pipe.sadd("books", book.isbn)
    pipe.sadd(f"books:author:{book.author.lower()}", book.isbn)
    pipe.execute()
    logger.info("Created book %s — %s", book.isbn, book.title)
    return _hash_to_book(r.hgetall(key))


@app.put("/books/{isbn}", tags=["books"])
def update_book(isbn: str, update: BookUpdate):
    """Partial update — only supplied fields are changed."""
    r = get_client()
    key = _book_key(isbn)
    if not r.exists(key):
        raise HTTPException(status_code=404, detail=f"Book '{isbn}' not found")
    patch = {k: str(v) for k, v in update.model_dump(exclude_none=True).items()}
    if patch:
        r.hset(key, mapping=patch)
    return _hash_to_book(r.hgetall(key))


@app.delete("/books/{isbn}", status_code=204, tags=["books"])
def delete_book(isbn: str):
    """Delete a book and remove it from all indexes."""
    r = get_client()
    key = _book_key(isbn)
    data = r.hgetall(key)
    if not data:
        raise HTTPException(status_code=404, detail=f"Book '{isbn}' not found")
    pipe = r.pipeline()
    pipe.delete(key)
    pipe.srem("books", isbn)
    if data.get("author"):
        pipe.srem(f"books:author:{data['author'].lower()}", isbn)
    pipe.execute()
    logger.info("Deleted book %s", isbn)
    return None


@app.get("/books/author/{author}", tags=["books"])
def books_by_author(author: str):
    """Return all books by a given author (case-insensitive)."""
    r = get_client()
    isbns = r.smembers(f"books:author:{author.lower()}")
    if not isbns:
        return []
    pipe = r.pipeline()
    for isbn in isbns:
        pipe.hgetall(_book_key(isbn))
    results = pipe.execute()
    return [_hash_to_book(b) for b in results if b]
