/**
 * Fixed-window counters, in memory only.
 *
 * Rate limiting here protects against notification spam, never against message
 * delivery: a throttled wake means a missing alert, and the ciphertext is still
 * sitting on Nostr for the next launch or background refresh to collect.
 */
export class RateLimiter {
  constructor({ now = () => Date.now() } = {}) {
    this._now = now;
    this._windows = new Map();
  }

  /**
   * True when this key is still under [limit] within [windowMs]. Counts the
   * call, so a refusal also consumes an attempt — a caller cannot probe the
   * limit for free.
   */
  allow(key, limit, windowMs) {
    const now = this._now();
    const bucket = Math.floor(now / windowMs);
    const id = `${key}:${windowMs}:${bucket}`;
    const count = (this._windows.get(id) ?? 0) + 1;
    this._windows.set(id, count);
    if (this._windows.size > 10000) this._sweep(now);
    return count <= limit;
  }

  _sweep(now) {
    for (const id of this._windows.keys()) {
      const [, windowMs, bucket] = id.split(':');
      if (Number(bucket) < Math.floor(now / Number(windowMs)) - 1) {
        this._windows.delete(id);
      }
    }
  }
}

/**
 * Holds a burst for the same device down to one push.
 *
 * Three contacts writing at once should ring the phone once, not three times,
 * and the alert says nothing about how many messages are waiting anyway — the
 * app finds that out when it fetches.
 */
export class Coalescer {
  constructor({ windowMs = 3000, now = () => Date.now() } = {}) {
    this._windowMs = windowMs;
    this._now = now;
    this._last = new Map();
  }

  /** True when this key should actually be delivered now. */
  shouldDeliver(key) {
    const now = this._now();
    const last = this._last.get(key) ?? 0;
    if (now - last < this._windowMs) return false;
    this._last.set(key, now);
    if (this._last.size > 10000) {
      for (const [k, at] of this._last) {
        if (now - at > this._windowMs * 10) this._last.delete(k);
      }
    }
    return true;
  }
}
