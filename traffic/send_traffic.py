# /// script
# requires-python = ">=3.13"
# dependencies = ["httpx>=0.28"]
# ///
"""Send synthetic blog comments to the spam filter or to the blog, and summarize the answers."""

import argparse
import asyncio
import random
import statistics
import time

import httpx

TOPICS = [
    "the playoffs",
    "your sourdough recipe",
    "the new laptop",
    "the city council vote",
    "the trail in Yosemite",
    "Python 3.13",
    "the jazz festival",
    "remote work",
]
HAM = [
    "Great post about {t}, I had the same experience last year.",
    "I disagree with your take on {t}, but it was an interesting read.",
    "Thanks for writing about {t}. Could you share more details?",
    "My family talked about {t} all weekend, thanks for the summary.",
    "Small correction: the numbers on {t} changed last month.",
    "I shared this article on {t} with my team, very helpful.",
    "Has anyone else tried this? My results with {t} were different.",
    "Loved the photos. When will you write the follow-up on {t}?",
]
SPAM = [
    "Earn $500 a day from home!!! Click here www.easy-money.biz",
    "Free crypto signals, 1000% profit guaranteed, join t.me/moonpump now",
    "Buy cheap v1agra online, no prescription, fast shipping",
    "Hot singles in your area want to meet you, visit datingnow.ru",
    "Congratulations, you won an iPhone! Claim your prize at win-prize.top",
    "Best SEO backlinks for your blog, 10000 links for $5, order today",
    "Lose 20 pounds in 2 weeks with this one weird trick, click my profile",
    "Investment opportunity: double your bitcoin in 24 hours, DM me",
]


def comments(n: int, spam_share: float, seed: int) -> list[tuple[str, bool]]:
    rng = random.Random(seed)
    out = []
    for _ in range(n):
        if rng.random() < spam_share:
            out.append((rng.choice(SPAM), True))
        else:
            out.append((rng.choice(HAM).format(t=rng.choice(TOPICS)), False))
    return out


async def send(client, args, text, results):
    start = time.perf_counter()
    try:
        if args.target == "filter":
            r = await client.post(f"{args.url}/check", json={"text": text})
        else:
            post = random.randint(1, 5)
            r = await client.post(
                f"{args.url}/posts/{post}/comments", json={"author": "reader", "text": text}
            )
        ok = r.status_code < 400
        body = r.json() if ok else None
    except httpx.HTTPError:
        ok, body = False, None
    results.append((text, ok, body, time.perf_counter() - start))


async def main(args):
    batch = comments(args.n, args.spam_share, args.seed)
    results: list = []
    headers = {"X-API-Key": args.api_key} if args.api_key else {}
    limit = asyncio.Semaphore(args.concurrency)
    async with httpx.AsyncClient(timeout=5, headers=headers) as client:

        async def one(text):
            async with limit:
                await send(client, args, text, results)
                if args.rate:
                    await asyncio.sleep(args.concurrency / args.rate)

        start = time.perf_counter()
        await asyncio.gather(*(one(text) for text, _ in batch))
        duration = time.perf_counter() - start

    ok = [r for r in results if r[1]]
    lat = sorted(r[3] * 1000 for r in ok)
    print(
        f"sent {len(batch)} comments in {duration:.1f} s: {len(ok)} ok, {len(batch) - len(ok)} failed"
    )
    if lat:
        p95 = lat[int(0.95 * (len(lat) - 1))]
        print(f"latency: median {statistics.median(lat):.0f} ms, p95 {p95:.0f} ms")
    if args.target == "filter" and ok:
        truth = dict(batch)
        flagged = sum(1 for _, _, body, _ in ok if body["spam"])
        correct = sum(1 for text, _, body, _ in ok if body["spam"] == truth[text])
        print(
            f"flagged as spam: {flagged} (true spam: {sum(s for _, s in batch)}), correct: {correct} of {len(ok)}"
        )


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--target", choices=["filter", "blog"], default="filter")
    p.add_argument("--url", default="http://localhost:8000")
    p.add_argument("-n", type=int, default=50, help="number of comments")
    p.add_argument("--spam-share", type=float, default=0.3)
    p.add_argument("--concurrency", type=int, default=4)
    p.add_argument(
        "--rate", type=float, default=0, help="comments per second (0 = as fast as possible)"
    )
    p.add_argument("--api-key")
    p.add_argument("--seed", type=int, default=1)
    asyncio.run(main(p.parse_args()))
