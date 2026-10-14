"""Local exchange calendar for observation only; never grants halt clearance."""
import json
from pathlib import Path
from datetime import datetime
from zoneinfo import ZoneInfo

CALENDAR_PATH=Path(__file__).with_name('us-equity-calendar-2026.json')
EQUITIES=('NVDAx','TSLAx','AMZNx','AAPLx','SPYx')

def session(symbol, timestamp, calendar_path=CALENDAR_PATH):
    result=dict(state='UNKNOWN',reason='CALENDAR_UNAVAILABLE',halt='UNKNOWN',
                basis='SCHEDULED_REGULAR_SESSION_ONLY',calendarVersion=None,
                opensAt=None,closesAt=None,tradingReady=False)
    if symbol=='BNB':
        return {**result,'state':'OPEN','reason':'CRYPTO_CONTINUOUS_REFERENCE','basis':'CRYPTO_REFERENCE_NOT_EQUITY_SESSION'}
    if symbol not in EQUITIES:return {**result,'reason':'UNSUPPORTED_ASSET'}
    try:
        if type(timestamp) not in (int,float) or timestamp<=0:raise ValueError('Invalid time')
        c=json.loads(Path(calendar_path).read_text(encoding='utf-8'))
        if c['version']!='US_EQUITY_CORE_2026_V1' or c['year']!=2026 or c['timezone']!='America/New_York':raise ValueError('Unsupported calendar')
        z=ZoneInfo(c['timezone']);now=datetime.fromtimestamp(timestamp,z);date=now.date().isoformat()
        if now.year!=c['year']:return {**result,'reason':'CALENDAR_YEAR_NOT_COVERED'}
        result['calendarVersion']=c['version']
        if now.weekday()>=5:return {**result,'state':'CLOSED','reason':'WEEKEND'}
        if date in c['holidays']:return {**result,'state':'CLOSED','reason':'EXCHANGE_HOLIDAY'}
        start=datetime.fromisoformat(date+'T'+c['open']).replace(tzinfo=z).timestamp()
        close=c['earlyCloses'].get(date,c['close'])
        end=datetime.fromisoformat(date+'T'+close).replace(tzinfo=z).timestamp()
        if end<=start:raise ValueError('Invalid session')
        result.update(opensAt=int(start),closesAt=int(end))
        if timestamp<start:return {**result,'state':'CLOSED','reason':'BEFORE_REGULAR_SESSION'}
        if timestamp>=end:return {**result,'state':'CLOSED','reason':'AFTER_EARLY_CLOSE' if date in c['earlyCloses'] else 'AFTER_REGULAR_SESSION'}
        return {**result,'state':'OPEN','reason':'SCHEDULED_EARLY_CLOSE_SESSION' if date in c['earlyCloses'] else 'SCHEDULED_REGULAR_SESSION'}
    except (OSError,ValueError,TypeError,KeyError,OverflowError):return result

def qualify(symbol, price_status, timestamp):
    s=session(symbol,timestamp)
    blockers=[]
    if price_status!='FRESH_REFERENCE_ONLY':blockers.append('STALE_PRICE' if price_status=='STALE_PRICE' else 'PRICE_UNAVAILABLE')
    if s['state']=='CLOSED':blockers.append('MARKET_CLOSED')
    elif s['state']=='UNKNOWN':blockers.append('MARKET_SESSION_UNKNOWN')
    if symbol in EQUITIES:blockers.append('HALT_STATUS_UNKNOWN')
    return dict(session=s,referenceUsable=price_status=='FRESH_REFERENCE_ONLY',
                scheduledSessionUsable=s['state']=='OPEN',tradingReady=False,blockers=blockers,
                status='BLOCKED' if blockers else 'REFERENCE_ONLY_NOT_EXECUTION_APPROVAL')
