"""Save a screenshot of the Grafana dashboard (for the README)."""

import os
import sys

from playwright.sync_api import sync_playwright

URL = "http://localhost:3000/d/blog-ops?orgId=1&from=now-6m&to=now&kiosk"
out = sys.argv[1] if len(sys.argv) > 1 else "dashboard.png"

with sync_playwright() as p:
    browser = p.chromium.launch(executable_path=os.environ.get("CHROMIUM_PATH"))
    page = browser.new_page(viewport={"width": 1600, "height": 1000})
    page.goto(URL, wait_until="networkidle")
    page.wait_for_timeout(3000)
    page.screenshot(path=out)
    browser.close()
print(f"saved {out}")
