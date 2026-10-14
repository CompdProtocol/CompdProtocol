"""Read-only independent equity observations. Never authorizes swaps or signing.

Alpaca IEX observations are not qualified xStocks/onchain oracle prices. Missing
halt coverage deliberately blocks readiness, even when a quote is fresh.
"""
import json
import os
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from urllib.request import Request, urlopen
from urllib.parse import urlencode
from zoneinfo import ZoneInfo

SYMBOLS = {s+'x': s for s in ('NVDA', 'TSLA', 'AMZN', 'AAPL', 'SPY')}

def timestamp(value):
    d = datetime.fromisoformat(value.replace('Z', '+00:00'))
    if d.tzinfo is None: raise ValueError('Timezone required')
    return d.timestamp()

def session_open(calendar, now):
    """Provider calendar, Eastern DST, holidays and early closes; no guesses."""
    local = datetime.fromtimestamp(now, ZoneInfo('America/New_York'))
    rows = [r for r in calendar if r['date'] == local.date().isoformat()]
    if len(rows) > 1: raise ValueError('Duplicate calendar date')
    if not rows: return False
    row = rows[0]
    def bound(key):
        return datetime.fromisoformat(row['date']+'T'+row[key]).replace(
            tzinfo=ZoneInfo('America/New_York')).timestamp()
    start, end = bound('open'), bound('close')
    if end <= start: raise ValueError('Invalid session')
    return start <= now < end

def observation(symbol, quote, calendar, now, *, halt=None):
    if symbol not in SYMBOLS: raise ValueError('Asset not approved')
    result = dict(symbol=symbol, underlyingSymbol=SYMBOLS[symbol],
                  provider='ALPACA_IEX', executionEnabled=False,
                  priceSourceVerified=False, status='NOT_VERIFIED', reasons=[])
    try:
        age = now - timestamp(quote['t'])
        bid, ask = Decimal(str(quote['bp'])), Decimal(str(quote['ap']))
        if not bid.is_finite() or not ask.is_finite() or not 0 < bid <= ask:
            raise ValueError('Invalid quote')
        if quote['bs'] <= 0 or quote['as'] <= 0: raise ValueError('Empty quote')
        if not 0 <= age <= 60: result['reasons'].append('STALE_OR_FUTURE_PRICE')
        midpoint = (bid+ask)/2
        if (ask-bid)*10000/midpoint > 100: result['reasons'].append('WIDE_SPREAD')
        result.update(underlyingUSD=str(midpoint), timestamp=quote['t'],
                      marketOpen=session_open(calendar, now))
        if not result['marketOpen']: result['reasons'].append('MARKET_CLOSED')
        # Only a separately qualified all-venue status source may supply this.
        # No current production collector does so; fresh quotes cannot prove it.
        if not halt or halt.get('coverage') != 'ALL_VENUES' or type(halt.get('halted')) is not bool:
            result['reasons'].append('HALT_STATUS_UNKNOWN')
        elif not 0 <= now-timestamp(halt['timestamp']) <= 60:
            result['reasons'].append('HALT_STATUS_STALE')
        elif halt['halted']: result['reasons'].append('TRADING_HALTED')
        result['observationUsable'] = not result['reasons']
    except (KeyError, ValueError, TypeError, InvalidOperation):
        result['reasons'].append('INVALID_PROVIDER_DATA')
        result['observationUsable'] = False
    return result

class AlpacaReader:
    """Fixed GET endpoints only; no orders, credential output or automatic retry."""
    def __init__(self, transport=None):
        self.transport = transport or self._get

    def _get(self, url):
        key, secret = os.getenv('COMPD_ALPACA_KEY_ID'), os.getenv('COMPD_ALPACA_SECRET_KEY')
        if not key or not secret: raise ValueError('ALPACA_READ_ONLY_ACCESS_REQUIRED')
        req = Request(url, headers={'APCA-API-KEY-ID': key, 'APCA-API-SECRET-KEY': secret})
        try:
            with urlopen(req, timeout=10) as response:
                payload = response.read(1000001)
                if len(payload) > 1000000: raise ValueError('Oversized response')
                return json.loads(payload)
        except Exception:
            raise ValueError('PROVIDER_UNAVAILABLE_NO_RETRY') from None

    def read(self, now):
        date = datetime.fromtimestamp(now, ZoneInfo('America/New_York')).date().isoformat()
        try:
            calendar = self.transport('https://paper-api.alpaca.markets/v2/calendar?'+urlencode({'start':date,'end':date}))
            quotes = self.transport('https://data.alpaca.markets/v2/stocks/quotes/latest?'+urlencode({'symbols':','.join(SYMBOLS.values()),'feed':'iex'}))['quotes']
            return {s: observation(s, quotes.get(u, {}), calendar, now) for s,u in SYMBOLS.items()}
        except Exception:
            return {s:dict(symbol=s, executionEnabled=False, status='NOT_VERIFIED',
                           observationUsable=False, reasons=['PROVIDER_ACCESS_OR_DATA_UNAVAILABLE']) for s in SYMBOLS}

if __name__ == '__main__':
    print(json.dumps(AlpacaReader().read(datetime.now(timezone.utc).timestamp()), indent=2))
