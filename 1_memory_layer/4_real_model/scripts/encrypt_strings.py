#!/usr/bin/env python3
"""
AES-256-CBC encryption tool for sensitive strings in CloudProvider.swift.

Usage:
    python3 scripts/encrypt_strings.py

Generates:
    - Key parts (4 x 32-byte arrays, XOR together to get the real key)
    - Encrypted base64 strings for each sensitive value
    - Ready-to-paste Swift code

To add/change a string, edit the STRINGS dict below and re-run.
"""

import os
import base64
import hashlib
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives import padding

# ── Sensitive strings to encrypt ──────────────────────────────────────────────

STRINGS = {
    "_openaiURL": "https://api.openai.com/v1/chat/completions",
    "_openrouterURL": "https://openrouter.ai/api/v1/chat/completions",
    "_qwenURL": "https://dashscope.aliyuncs.com/compatible-oode/v1/chat/completions",
    "_openaiModel": "gpt-4.1",
    "_openrouterModel": "qwen/qwen3-30b-a3b",
    "_qwenModel": "qwen-turbo",
    "_deepinfra": "DeepInfra",
    "_screenContextLabel": '[SCREEN CONTEXT \u2013 for reference only, do NOT continue this text]',
    "_userTypingLabel": '[USER IS TYPING \u2013 continue THIS text as the same author]',
    "_screenContextPrefill": '[SCREEN CONTEXT \u2013 for reference only]',
    "_prefillInstruction": 'Continue the text below as the same author. Output only the natural continuation.',
    "_systemPrompt": (
        "You are an inline autocomplete engine.\n\n"
        "Rules:\n"
        "- Output ONLY the new text that comes AFTER the cursor position\n"
        "- NEVER repeat any text that already exists before the cursor\n"
        "- Match the existing formatting, language, and tone\n"
        "- Keep completions concise and natural\n"
        "- You are predicting what the SAME author will write next. Do not answer questions, fulfill requests, or reply as if you are a different person in a conversation.\n"
        '  - Prefix "Do you want to go to the bar tonight?" \u2192 WRONG: " Yes, I\'d love to" (answering as someone else)\n'
        '  - Prefix "Do you want to go to the bar tonight?" \u2192 RIGHT: " Let me know when you\'re free." (same author continuing)\n'
        "- CRITICAL spacing rule: Your output is inserted exactly at the cursor position. You MUST include a leading space when starting a new word. Examples:\n"
        '  - Prefix "What if we" \u2192 output " could try" (space before "could")\n'
        '  - Prefix "I think" \u2192 output " that\'s a great idea" (space before "that\'s")\n'
        '  - Prefix "superfi" \u2192 output "cial" (NO space, completing the word)\n'
        '  - Prefix "non-na" \u2192 output "tural" (NO space, completing the word)\n'
        "- Do NOT think or reason. Respond immediately with the completion text only. /no_think"
    ),
}

# ── Encryption ────────────────────────────────────────────────────────────────

def generate_split_key():
    """Generate an AES-256 key split into 4 parts (XOR together to recover)."""
    real_key = os.urandom(32)
    part1 = os.urandom(32)
    part2 = os.urandom(32)
    part3 = os.urandom(32)
    # part4 = real_key XOR part1 XOR part2 XOR part3
    part4 = bytes(a ^ b ^ c ^ d for a, b, c, d in zip(real_key, part1, part2, part3))
    # Verify: part1 ^ part2 ^ part3 ^ part4 == real_key
    recovered = bytes(a ^ b ^ c ^ d for a, b, c, d in zip(part1, part2, part3, part4))
    assert recovered == real_key, "Key recovery check failed"
    return real_key, [part1, part2, part3, part4]


def encrypt_string(plaintext: str, key: bytes) -> str:
    """Encrypt with AES-256-CBC, prepend random IV, return base64."""
    iv = os.urandom(16)
    padder = padding.PKCS7(128).padder()
    padded = padder.update(plaintext.encode("utf-8")) + padder.finalize()
    cipher = Cipher(algorithms.AES(key), modes.CBC(iv))
    encryptor = cipher.encryptor()
    ciphertext = encryptor.update(padded) + encryptor.finalize()
    return base64.b64encode(iv + ciphertext).decode("ascii")


def format_bytes_swift(data: bytes, name: str) -> str:
    """Format a byte array as a Swift array literal."""
    hex_vals = ", ".join(f"0x{b:02X}" for b in data)
    return f"    private static let {name}: [UInt8] = [{hex_vals}]"


def main():
    key, parts = generate_split_key()

    print("// MARK: - AES key parts (XOR all 4 to recover the 256-bit key)\n")
    for i, part in enumerate(parts):
        print(format_bytes_swift(part, f"_kp{i}"))
    print()

    print("// MARK: - AES-encrypted strings (IV + ciphertext, base64)\n")
    for name, plaintext in STRINGS.items():
        encrypted = encrypt_string(plaintext, key)
        # Split long base64 into multiple lines for readability
        if len(encrypted) > 80:
            lines = [encrypted[i:i+80] for i in range(0, len(encrypted), 80)]
            joined = '" +\n        "'.join(lines)
            print(f'    private static let {name} = _d(\n        "{joined}"\n    )')
        else:
            print(f'    private static let {name} = _d("{encrypted}")')
        print()

    # Also output a verification block
    print("\n// ── Verification (run in debug to confirm decryption works) ──")
    print("// Expected plaintext values:")
    for name, plaintext in STRINGS.items():
        preview = plaintext[:60].replace("\n", "\\n")
        if len(plaintext) > 60:
            preview += "..."
        print(f"//   {name}: \"{preview}\"")


if __name__ == "__main__":
    main()
