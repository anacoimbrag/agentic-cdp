"""API REST que expõe os 3 casos de uso de ML do CDP (segmentação, próxima
campanha, vitrine personalizada). Lê só de output/serving_store.sqlite,
gravado por ml/export_to_serving_store.py — nunca do ClickHouse diretamente.
"""

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from api.routers import campaigns, customers, segments, showcase

app = FastAPI(
    title="agentic-cdp ML API",
    description="Segmentação dinâmica, próxima campanha sugerida e vitrine personalizada.",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:5173"],
    allow_methods=["GET"],
    allow_headers=["*"],
)

app.include_router(customers.router, tags=["customers"])
app.include_router(segments.router, tags=["segments"])
app.include_router(campaigns.router, tags=["campaigns"])
app.include_router(showcase.router, tags=["showcase"])


@app.get("/health")
def health() -> dict:
    return {"status": "ok"}
