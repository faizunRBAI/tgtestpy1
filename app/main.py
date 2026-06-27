from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles
from fastapi.responses import HTMLResponse
import pathlib

from app.routers import health, api

app = FastAPI(title="tgtestpy1", version="1.0.0")

# Mount static files if directory exists
_static = pathlib.Path(__file__).parent.parent / 'public'
if _static.exists():
    app.mount('/public', StaticFiles(directory=str(_static)), name='static')

app.include_router(health.router, prefix='/health', tags=['health'])
app.include_router(api.router,    prefix='/api',    tags=['api'])

@app.get('/', response_class=HTMLResponse)
def root():
    html = pathlib.Path(__file__).parent.parent / 'public' / 'index.html'
    if html.exists():
        return HTMLResponse(content=html.read_text())
    return HTMLResponse(content='<h1>App is running</h1>')
