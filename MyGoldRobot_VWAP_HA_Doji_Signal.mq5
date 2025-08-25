input uint     InpMagic                   = 2025082502;
input bool     InpOnePositionPerSymbol    = true;

CTrade Trade;
string g_symbol;
MqlTick g_tick;
int g_digits; double g_point; double g_tickValue; double g_tickSize; int g_spread_points;

datetime g_lastBuySignalBarTime = 0;
datetime g_lastSellSignalBarTime = 0;

bool GetSymbolProps(const string sym)
{
	g_symbol = sym;
	g_digits = (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS);
	g_point  = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
	g_tickValue = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_VALUE);
	g_tickSize  = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_SIZE);
	g_spread_points = (int)SymbolInfoInteger(g_symbol, SYMBOL_SPREAD);
	return(SymbolInfoTick(g_symbol, g_tick));
}

bool EnsureSymbolReady()
{
	string target = InpSymbol;
	if(target == NULL || StringLen(target) == 0) target = _Symbol;
	// Ensure symbol visible in Market Watch
	SymbolSelect(target, true);
	if(!SymbolInfoTick(target, g_tick))
	{
		// Fallback to chart symbol
		target = _Symbol;
		SymbolSelect(target, true);
		if(!SymbolInfoTick(target, g_tick))
		{
			Print("[EA] No tick data for symbol. Tried: ", InpSymbol, " and ", _Symbol);
			return(false);
		}
	}
	return(GetSymbolProps(target));
}

int OnInit(){
	// Initialize symbol props with fallback; do not detach on failure
	if(!EnsureSymbolReady())
	{
		Print("[EA] Initialization without active symbol. EA will retry on ticks.");
	}
	Trade.SetExpertMagicNumber(InpMagic);
	return(INIT_SUCCEEDED);
}

void OnTick()
{
	// Refresh symbol props; fallback to chart symbol if needed
	if(!EnsureSymbolReady()) return;
	if(DailyDrawdownExceeded()) return;
	if(!IsWithinSessions(TimeCurrent())) return;
	CloseAllPositionsBeforeNews();
	ManageOpenPosition();
	EvaluateAndTrade();
}

void OnDeinit(const int reason){}