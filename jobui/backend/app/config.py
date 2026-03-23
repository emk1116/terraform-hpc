from pydantic_settings import BaseSettings
from functools import lru_cache


class Settings(BaseSettings):
    jwt_secret: str = "change-me-in-production"
    jwt_algorithm: str = "HS256"
    jwt_expire_minutes: int = 480

    s3_bucket: str = ""
    aws_region: str = "us-east-1"
    s3_presigned_expiry: int = 3600

    fsx_base: str = "/fsx/work"
    slurm_partition: str = "main"

    db_path: str = "/data/hpc.db"
    default_users: str = "admin:admin123:user1:1,user1:user1pass:user1:0,user2:user2pass:user2:0"

    class Config:
        env_file = ".env"


@lru_cache
def get_settings() -> Settings:
    return Settings()
