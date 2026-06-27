import os
from fastapi import APIRouter

router = APIRouter()

@router.get('/info')
def api_info():
    db_status = 'not-required'
    return {
        'app': 'fastapi',
        'version': '1.0.0',
        'db': db_status,
        'env': os.getenv('APP_ENV', 'development'),
    }

# Add your own routes below
# @router.get('/users')
# def list_users(): ...
