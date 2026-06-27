import os

class Settings:
    PORT: int = 8000
    HOST: str = '0.0.0.0'

    def __init__(self):
        for field, default in self.__class__.__annotations__.items():
            val = os.getenv(field.upper())
            setattr(self, field, type(getattr(self.__class__, field))(val) if val is not None else getattr(self.__class__, field))

settings = Settings()
