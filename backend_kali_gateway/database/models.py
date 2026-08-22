from sqlalchemy import Column, Integer, String, Boolean, DateTime, Float, func
try:
    from database.db_core import Base       # when run from backend_kali_gateway/
except ImportError:
    from .db_core import Base               # when imported as a package


class Admin(Base):
    """Admin identity bound to a specific device and laptop MAC."""
    __tablename__ = "users"                 # matches Supabase table name

    id             = Column(Integer, primary_key=True, index=True)
    username       = Column(String, unique=True, index=True)
    password_hash  = Column(String)
    role           = Column(String, default="admin")
    device_id      = Column(String, unique=True, index=True)
    public_key_pem = Column(String)
    locked_mac     = Column(String)         # IP/MAC bound on first knock


class VendorSession(Base):
    """JIT vendor session — aligned with Supabase vendor_sessions schema."""
    __tablename__ = "vendor_sessions"

    id              = Column(Integer, primary_key=True, index=True)
    qr_token        = Column(String, unique=True, index=True)
    vendor_username = Column(String)
    company_name    = Column(String)
    clearance_level = Column(String, default="standard")
    status          = Column(String, default="pending")  # pending / active / expired
    valid_until     = Column(String)
    created_at      = Column(DateTime, default=func.now())
    last_seen_lat   = Column(Float)
    last_seen_lng   = Column(Float)
    last_seen_at    = Column(DateTime)
