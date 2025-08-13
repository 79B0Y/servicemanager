from __future__ import annotations

from typing import Optional

from .ha import HAIntegration

_ha_ref: Optional[HAIntegration] = None


def set_ha(ha: HAIntegration) -> None:
    global _ha_ref
    _ha_ref = ha


def get_ha() -> Optional[HAIntegration]:
    return _ha_ref

