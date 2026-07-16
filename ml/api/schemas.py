"""Modelos de resposta Pydantic da API."""

from __future__ import annotations

from typing import Optional

from pydantic import BaseModel


class CustomerSummary(BaseModel):
    customer_id: str
    full_name: Optional[str] = None


class SegmentResponse(BaseModel):
    customer_id: str
    cluster_id: Optional[int] = None
    segment_label: Optional[str] = None
    tier: Optional[str] = None
    segmented_at: Optional[str] = None


class SegmentSummary(BaseModel):
    segment_label: str
    customer_count: int


class CampaignResponse(BaseModel):
    customer_id: str
    promotion_id: Optional[str] = None
    promotion_name: Optional[str] = None
    score: Optional[float] = None
    reason: Optional[str] = None
    scored_at: Optional[str] = None


class ShowcaseItem(BaseModel):
    rank: int
    product_id: str
    sku_id: Optional[str] = None
    product_name: Optional[str] = None
    price: Optional[float] = None
    image_url: Optional[str] = None
    reason: str
    score: float


class ShowcaseResponse(BaseModel):
    customer_id: str
    items: list[ShowcaseItem]
