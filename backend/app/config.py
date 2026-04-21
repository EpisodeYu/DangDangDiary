from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    APP_NAME: str = "当当日记"
    DEBUG: bool = True
    PUBLIC_BASE_URL: str = "http://YOUR_SERVER_IP"

    # Database
    DATABASE_URL: str = "postgresql+asyncpg://dangdang:dangdang_dev@127.0.0.1:5432/dangdang"
    DB_ECHO: bool = False
    DB_POOL_SIZE: int = 10
    DB_MAX_OVERFLOW: int = 20
    DB_POOL_RECYCLE: int = 1800

    # Redis
    REDIS_URL: str = "redis://127.0.0.1:6379/0"

    # MinIO (internal access)
    MINIO_ENDPOINT: str = "127.0.0.1:9000"
    # Externally-reachable host:port for MinIO. Used to mint presigned URLs
    # that third parties (DashScope STT) can fetch. Leave empty to derive
    # `<PUBLIC_BASE_URL host>:9000` at call time.
    MINIO_PUBLIC_ENDPOINT: str = ""
    MINIO_ACCESS_KEY: str = "minioadmin"
    MINIO_SECRET_KEY: str = "minioadmin123"
    MINIO_SECURE: bool = False
    MINIO_BUCKET_PHOTOS: str = "pet-photos"
    MINIO_BUCKET_THUMBNAILS: str = "pet-thumbnails"
    MINIO_BUCKET_AVATARS: str = "avatars"

    # JWT
    JWT_SECRET_KEY: str = "your-secret-key-change-in-production"
    JWT_ALGORITHM: str = "HS256"
    ACCESS_TOKEN_EXPIRE_MINUTES: int = 120
    REFRESH_TOKEN_EXPIRE_DAYS: int = 30

    # Aliyun AccessKey (SMS + image recognition)
    ALIYUN_ACCESS_KEY_ID: str = ""
    ALIYUN_ACCESS_KEY_SECRET: str = ""

    # Aliyun NLS (智能语音交互) AppKey. Not used by the production STT path
    # anymore — DashScope fun-asr is preferred (see §0.5.1 of the voice
    # intake doc). Kept so it can be wired up ad-hoc by
    # `scripts/stt_bench.py` and so the field can live in `.env` without
    # tripping pydantic's forbid-extra check.
    ALIYUN_STT_APP_KEY: str = ""

    # SMS (Aliyun Dypnsapi)
    ALIYUN_SMS_SIGN_NAME: str = "速通互联验证码"
    ALIYUN_SMS_TEMPLATE_CODE: str = "100001"

    # Image recognition (Aliyun RecognizeScene)
    # Client runs a TFLite model locally; server-side recognition is kept as
    # a switchable fallback. Flip to True to re-enable Aliyun RecognizeScene.
    ENABLE_SERVER_PET_RECOGNITION: bool = False
    ALIYUN_IMAGERECOG_ENDPOINT: str = "imagerecog.cn-shanghai.aliyuncs.com"
    ALIYUN_IMAGERECOG_REGION: str = "cn-shanghai"

    # DashScope (Phase 2 Step 2 voice intake)
    #
    # Split by region on purpose (benchmarked 2026-04-21 from the Tokyo
    # origin, N=10 on a 3.1s / 16kHz clip; see `scripts/stt_bench.py`):
    #
    #                                      p50     p90    success
    #   Beijing paraformer-v1 (legacy)     6.34s   7.24s  10/10
    #   Beijing fun-asr                    6.28s  84.2s   10/10 (134s tail!)
    #   Singapore fun-asr  (current)       2.60s   4.33s  10/10
    #
    # Root cause: TLS handshake Tokyo→dashscope.aliyuncs.com ≈ 3.2s
    # vs Tokyo→dashscope-intl.aliyuncs.com ≈ 0.08s (40× difference).
    # STT therefore uses the Singapore region + fun-asr by default,
    # falling back to the Beijing key + paraformer-v1 if the SG key is
    # not configured. LLM and embedding still default to the Beijing
    # key since qwen-plus / multimodal-embedding-v1 pricing & quota
    # live there and the OpenAI-compatible endpoint for LLM is less
    # latency-sensitive.
    DASHSCOPE_API_KEY: str = ""            # Beijing region (LLM/embedding fallback + STT fallback)
    DASHSCOPE_API_KEY_SAG: str = ""        # Singapore region (preferred for STT + LLM)
    DASHSCOPE_BASE_URL: str = "https://dashscope.aliyuncs.com/compatible-mode/v1"
    DASHSCOPE_BASE_URL_SAG: str = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
    DASHSCOPE_STT_BASE_URL: str = "https://dashscope-intl.aliyuncs.com/api/v1"
    DASHSCOPE_STT_FALLBACK_BASE_URL: str = "https://dashscope.aliyuncs.com/api/v1"
    DASHSCOPE_STT_MODEL: str = "fun-asr"                # Singapore region
    DASHSCOPE_STT_FALLBACK_MODEL: str = "paraformer-v1"  # Beijing region
    # LLM: measured 2026-04-21 on the Singapore region — qwen-plus p50
    # 2.32s / p90 2.51s with zero auth/retry errors and 100% field
    # accuracy on the voice-intake golden set; Beijing p50 ~4.4s / max
    # 9.4s for the same model + prompt (TLS handshake Tokyo→BJ ≈ 3.2s,
    # SG ≈ 0.08s). qwen-flash is 2× faster but has a stable template
    # bug producing `3_days_ago:3` instead of `N_days_ago:3`; stick
    # with qwen-plus until that's compensated for server-side.
    TONGYI_MODEL: str = "qwen-plus"

    # Voice intake hard limits (front/back both enforce)
    VOICE_INTAKE_MAX_SECONDS: int = 30
    VOICE_INTAKE_MAX_MB: int = 2
    VOICE_AUDIO_TTL_HOURS: int = 24
    MINIO_BUCKET_VOICE_INTAKE: str = "voice-intake"

    model_config = {"env_file": ".env"}


settings = Settings()
