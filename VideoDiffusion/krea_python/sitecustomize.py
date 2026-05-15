import builtins
import os
from typing import Any


def _force_sdpa(module: Any) -> None:
    for flag in (
        "FLASH_ATTN_AVAILABLE",
        "FLASH_ATTN_2_AVAILABLE",
        "FLASH_ATTN_3_AVAILABLE",
        "FLASHATTN_AVAILABLE",
        "USE_FLASH_ATTN",
    ):
        if hasattr(module, flag):
            setattr(module, flag, False)

    for func in (
        "flash_attn_func",
        "flash_attn_varlen_func",
        "flash_attn_qkvpacked_func",
        "flash_attn_with_kvcache",
    ):
        if hasattr(module, func):
            setattr(module, func, None)


def _patch_forced_sdpa_import() -> None:
    original_import = builtins.__import__

    def patched_import(name, globals=None, locals=None, fromlist=(), level=0):
        mod = original_import(name, globals, locals, fromlist, level)
        try:
            if name == "wan.modules.attention":
                _force_sdpa(mod)
            elif hasattr(mod, "attention"):
                _force_sdpa(getattr(mod, "attention"))
        except Exception:
            pass
        return mod

    builtins.__import__ = patched_import


backend = os.environ.get("KREA_ATTN_BACKEND", "").strip().lower()
if backend == "sdpa":
    os.environ.setdefault("DISABLE_SAGEATTENTION", "1")
    _patch_forced_sdpa_import()
