from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    APP_NAME: str = "当当日记"
    DEBUG: bool = True
    PUBLIC_BASE_URL: str = "http://YOUR_SERVER_IP"

    # Database
    DATABASE_URL: str = "postgresql+asyncpg://dangdang:dangdang_dev@127.0.0.1:5432/dangdang"

    # Redis
    REDIS_URL: str = "redis://127.0.0.1:6379/0"

    # MinIO (internal access)
    MINIO_ENDPOINT: str = "127.0.0.1:9000"
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

    # SMS (Aliyun Dypnsapi)
    ALIYUN_SMS_SIGN_NAME: str = "速通互联验证码"
    ALIYUN_SMS_TEMPLATE_CODE: str = "100001"

    # Image recognition (Aliyun RecognizeScene)
    ALIYUN_IMAGERECOG_ENDPOINT: str = "imagerecog.cn-shanghai.aliyuncs.com"
    ALIYUN_IMAGERECOG_REGION: str = "cn-shanghai"

    model_config = {"env_file": ".env"}


settings = Settings()
