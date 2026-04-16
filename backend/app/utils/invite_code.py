import random

INVITE_CODE_CHARS = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"


def generate_invite_code(length: int = 6) -> str:
    return "".join(random.choices(INVITE_CODE_CHARS, k=length))
