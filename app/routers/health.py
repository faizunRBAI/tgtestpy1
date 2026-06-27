from fastapi import APIRouter
import time

router = APIRouter()
_start = time.time()

@router.get('/')
def health_check():
    return {'status': 'ok', 'uptime': round(time.time() - _start, 1)}
