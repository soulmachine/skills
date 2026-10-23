#!/usr/bin/env python3
"""Self-check for the copy-numbering logic: python3 test_multi_app.py"""
from multi_app import copy_numbers, next_number

assert next_number(["WeChat.app", "Safari.app"], "WeChat") == 2
assert next_number(["WeChat.app", "WeChat2.app", "WeChat3.app"], "WeChat") == 4
assert next_number(["WeChat.app", "WeChat3.app"], "WeChat") == 2  # fills the gap
assert copy_numbers(["WeChat2.app", "WeChatX.app", "WeChat2.app.bak", "OldWeChat5.app"], "WeChat") == {2}
print("ok")
