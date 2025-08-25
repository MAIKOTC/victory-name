#property copyright   "GPT-5"
#property link        "https://"
#property version     "1.1"
#property description "ETHUSD M1 VWAP+HA+Doji with ATR SL/TP, sessions, risk, visuals"
#property strict

#include <Trade/Trade.mqh>

//============================ Inputs ============================//
input string   InpSymbol                  = "ETHUSD";          // Trading symbol (broker symbol)
input ENUM_TIMEFRAMES InpTimeframe        = PERIOD_M1;         // Operating timeframe

// Sessions (GMT+2 by default)
input int      InpSessionsTzOffsetHours   = 2;                 // Sessions timezone offset relative to GMT
input bool     InpEnableLondonSession     = true;              // Enable London session filter
input int      InpLondonStartHour         = 7;                 // London start hour (GMT+2)
input int      InpLondonEndHour           = 16;                // London end hour (GMT+2)
input bool     InpEnableNewYorkSession    = true;              // Enable New York session filter
input int      InpNewYorkStartHour        = 13;                // New York start hour (GMT+2)
input int      InpNewYorkEndHour          = 22;                // New York end hour (GMT+2)

// Risk
input bool     InpUseRiskSizing           = true;              // Use risk-based sizing
input double   InpRiskPerTradePercent     = 0.3;               // Risk per trade (% of balance)
input double   InpFixedLot                = 0.01;              // Fixed lot if risk sizing is off
input double   InpMaxDailyDrawdownUSD     = 100.0;             // Max daily drawdown (stop trading when exceeded)

// Indicators
input int      InpATRPeriod               = 14;                // ATR period
input double   InpATRMultiplier           = 1.5;               // ATR multiplier for SL/TP
input int      InpLookbackMaxBars         = 10;                // Lookback bars for wickless HA run
input double   InpDojiMaxBodyPctOfRange   = 10.0;              // Doji: body <= this % of range
input bool     InpRequireDojiBodyGreaterPrevWickless = true;   // Doji body > prev 2 wickless HA bodies

// Trade management
input bool     InpEnablePartialTP         = true;              // Enable partial TP (50% at 1R)
input bool     InpEnableTrailingAfterPTP  = true;              // Enable ATR trailing after partial TP

// News filter (stub)
input bool     InpEnableNewsFilter        = false;             // Use economic calendar filter (stubbed)
input int      InpNewsCloseMinsBefore     = 10;                // Close trades X minutes before high-impact news

// Visuals
input bool     InpVisualAnnotations       = true;              // Draw entries and SL/TP on chart
input color    InpBuyColor                = clrLime;           // Buy marker color
input color    InpSellColor               = clrTomato;         // Sell marker color
input color    InpSLColor                 = clrOrange;         // SL line color
input color    InpTPColor                 = clrDeepSkyBlue;    // TP line color
input bool     InpShowWicklessMarkers     = true;              // Mark wickless HA candles within lookback
input color    InpWicklessBullColor       = clrGreen;          // Bullish wickless color
input color    InpWicklessBearColor       = clrRed;            // Bearish wickless color
input bool     InpShowRRLabel             = true;              // Show RR text near entry

// Misc
input uint     InpMagic                   = 2025082502;        // Magic number
input bool     InpOnePositionPerSymbol    = true;              // Allow only one open position per symbol

//============================ Globals ============================//
CTrade         Trade;
string         g_symbol;
MqlTick        g_tick;
int            g_digits;
double         g_point;
double         g_tickValue;
double         g_tickSize;
int            g_spread_points;

datetime       g_lastBuySignalBarTime = 0;
datetime       g_lastSellSignalBarTime = 0;

// Debug/visual state
bool   g_dbgDoji = false;
bool   g_dbgBuyTrend = false;
bool   g_dbgSellTrend = false;
bool   g_dbgHasBearishRun = false;
bool   g_dbgHasBullishRun = false;
double g_dbgVWAP = 0.0;

//============================ Helpers ============================//
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

bool IsWithinSessions(datetime t_server)
{
	// Convert server time to GMT
	datetime t_gmt = TimeGMT();
	int tz = InpSessionsTzOffsetHours;
	// Convert to sessions timezone
	datetime t_session = t_gmt + tz * 3600;
	MqlDateTime dt; TimeToStruct(t_session, dt);
	int hour = dt.hour;
	bool london = InpEnableLondonSession && (hour >= InpLondonStartHour && hour < InpLondonEndHour);
	bool ny     = InpEnableNewYorkSession && (hour >= InpNewYorkStartHour && hour < InpNewYorkEndHour);
	return(london || ny);
}

bool DailyDrawdownExceeded()
{
	MqlDateTime d; TimeToStruct(TimeCurrent(), d);
	d.hour = 0; d.min = 0; d.sec = 0;
	datetime day_start = StructToTime(d);
	// Compute realized PnL for today
	double realized = 0.0;
	int total = (int)HistoryDealsTotal();
	for(uint i=0; i<(uint)total; ++i)
	{
		ulong ticket = HistoryDealGetTicket(i);
		if(ticket == 0) continue;
		int deal_type = (int)HistoryDealGetInteger(ticket, DEAL_TYPE);
		if(!(deal_type == DEAL_TYPE_BUY || deal_type == DEAL_TYPE_SELL))
			continue; // skip non-trade deals
		datetime t   = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);
		if(t < day_start) continue;
		string sym  = HistoryDealGetString(ticket, DEAL_SYMBOL);
		if(sym != g_symbol) continue;
		double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT) + HistoryDealGetDouble(ticket, DEAL_SWAP) + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
		realized += profit;
	}
	return(realized <= -InpMaxDailyDrawdownUSD);
}

bool HasHighImpactNewsWithinMinutes(int minutes_ahead)
{
	// Stubbed out for broad terminal compatibility
	return(false);
}

void CloseAllPositionsBeforeNews()
{
	if(!InpEnableNewsFilter) return;
	if(!HasHighImpactNewsWithinMinutes(InpNewsCloseMinsBefore)) return;
	// Close all positions for symbol
	int positions = PositionsTotal();
	for(int i=positions-1; i>=0; --i)
	{
		ulong ticket = PositionGetTicket(i);
		if(ticket == 0) continue;
		if(!PositionSelectByTicket(ticket)) continue;
		string sym = PositionGetString(POSITION_SYMBOL);
		if(sym != g_symbol) continue;
		Trade.PositionClose(sym);
	}
}

//============================ Indicators ============================//
int CopyRatesSafe(string sym, ENUM_TIMEFRAMES tf, int count, MqlRates &rates[])
{
	ArraySetAsSeries(rates, true);
	int copied = CopyRates(sym, tf, 0, count, rates);
	return(copied);
}

bool ComputeATR(string sym, ENUM_TIMEFRAMES tf, int period, int count, double &atr[])
{
	ArraySetAsSeries(atr, true);
	int handle = iATR(sym, tf, period);
	if(handle == INVALID_HANDLE) return(false);
	int copied = CopyBuffer(handle, 0, 0, count, atr);
	IndicatorRelease(handle);
	return(copied == count);
}

// Heikin Ashi computation (series arrays, index 0 = current)
bool ComputeHeikinAshi(const MqlRates &rates[], int count, double &ha_open[], double &ha_close[], double &ha_high[], double &ha_low[])
{
	if(count <= 0) return(false);
	ArraySetAsSeries(ha_open,  true);
	ArraySetAsSeries(ha_close, true);
	ArraySetAsSeries(ha_high,  true);
	ArraySetAsSeries(ha_low,   true);

	// Initialize from the oldest bar
	int last = count - 1;
	double prev_ha_close = (rates[last].open + rates[last].high + rates[last].low + rates[last].close) / 4.0;
	double prev_ha_open  = (rates[last].open + rates[last].close) / 2.0;
	ha_close[last] = prev_ha_close;
	ha_open[last]  = prev_ha_open;
	ha_high[last]  = MathMax(rates[last].high, MathMax(prev_ha_open, prev_ha_close));
	ha_low[last]   = MathMin(rates[last].low,  MathMin(prev_ha_open, prev_ha_close));

	for(int i=last-1; i>=0; --i)
	{
		double ha_c = (rates[i].open + rates[i].high + rates[i].low + rates[i].close) / 4.0;
		double ha_o = (ha_open[i+1] + ha_close[i+1]) / 2.0;
		ha_close[i] = ha_c;
		ha_open[i]  = ha_o;
		ha_high[i]  = MathMax(rates[i].high, MathMax(ha_o, ha_c));
		ha_low[i]   = MathMin(rates[i].low,  MathMin(ha_o, ha_c));
	}
	return(true);
}

// Intraday VWAP (anchored to day start in sessions timezone)
bool ComputeVWAP(const MqlRates &rates[], int count, double &vwap[])
{
	ArraySetAsSeries(vwap, true);
	if(count <= 0) return(false);
	// Determine day start in sessions timezone per bar
	int tz = InpSessionsTzOffsetHours;
	double cumulative_pv = 0.0;
	double cumulative_v  = 0.0;
	MqlDateTime d;
	int current_day_yday = -1;
	for(int i=count-1; i>=0; --i)
	{
		// Convert rate time to sessions timezone
		datetime t_gmt = rates[i].time - (TimeCurrent() - TimeGMT()); // approximate bar GMT by shifting server->GMT
		datetime t_session = t_gmt + tz * 3600;
		TimeToStruct(t_session, d);
		int yday = d.day + d.mon*32 + d.year*500; // simple day key
		if(yday != current_day_yday)
		{
			cumulative_pv = 0.0;
			cumulative_v  = 0.0;
			current_day_yday = yday;
		}
		double typical = (rates[i].high + rates[i].low + rates[i].close) / 3.0;
		double vol     = (double)rates[i].tick_volume;
		cumulative_pv += typical * vol;
		cumulative_v  += vol;
		vwap[i] = (cumulative_v > 0.0 ? cumulative_pv / cumulative_v : typical);
	}
	return(true);
}

//============================ Strategy Logic ============================//
bool IsBullishHA(int i, const double &ha_open[], const double &ha_close[])
{
	return(ha_close[i] > ha_open[i]);
}

bool IsBearishHA(int i, const double &ha_open[], const double &ha_close[])
{
	return(ha_close[i] < ha_open[i]);
}

bool IsBullishWicklessHA(int i, const double &ha_open[], const double &ha_close[], const double &ha_low[])
{
	// No lower wick: HA_low equals min(open, close)
	double low_pivot = MathMin(ha_open[i], ha_close[i]);
	return(IsBullishHA(i, ha_open, ha_close) && MathAbs(ha_low[i] - low_pivot) <= (g_point * 0.1));
}

bool IsBearishWicklessHA(int i, const double &ha_open[], const double &ha_close[], const double &ha_high[])
{
	// No upper wick: HA_high equals max(open, close)
	double high_pivot = MathMax(ha_open[i], ha_close[i]);
	return(IsBearishHA(i, ha_open, ha_close) && MathAbs(ha_high[i] - high_pivot) <= (g_point * 0.1));
}

bool HasConsecutiveWicklessRun(bool bearish, int lookback, const double &ha_open[], const double &ha_close[], const double &ha_high[], const double &ha_low[])
{
	// Search last `lookback` bars BEFORE current bar (exclude index 0)
	int found_run = 0;
	for(int i=1; i<=lookback; ++i)
	{
		bool ok = bearish ? IsBearishWicklessHA(i, ha_open, ha_close, ha_high)
						 : IsBullishWicklessHA(i, ha_open, ha_close, ha_low);
		if(ok)
		{
			found_run++;
			if(found_run >= 2) return(true);
		}
		else
		{
			// If any opposite candle appears, reset (no opposite in between)
			bool opposite = bearish ? IsBullishHA(i, ha_open, ha_close) : IsBearishHA(i, ha_open, ha_close);
			if(opposite) found_run = 0; else found_run = 0; // reset
		}
	}
	return(false);
}

bool IsDoji(int i_candle, const MqlRates &rates[], const double &ha_open[], const double &ha_close[], int prev_index_1, int prev_index_2)
{
	double body = MathAbs(rates[i_candle].close - rates[i_candle].open);
	double range = MathMax(rates[i_candle].high - rates[i_candle].low, g_point);
	double body_pct = (body / range) * 100.0;
	if(body_pct > InpDojiMaxBodyPctOfRange) return(false);
	if(InpRequireDojiBodyGreaterPrevWickless)
	{
		double prev_body1 = MathAbs(ha_close[prev_index_1] - ha_open[prev_index_1]);
		double prev_body2 = MathAbs(ha_close[prev_index_2] - ha_open[prev_index_2]);
		if(!(body > prev_body1 && body > prev_body2)) return(false);
	}
	return(true);
}

bool VWAPFilterIsBuy(const double &vwap[])
{
	return(g_tick.ask > vwap[0]);
}

bool VWAPFilterIsSell(const double &vwap[])
{
	return(g_tick.bid < vwap[0]);
}

//============================ Orders & Risk ============================//
double CalculateRiskLotByStopUSD(double stop_distance_points)
{
	if(stop_distance_points <= 0.0) return(InpFixedLot);
	double balance = AccountInfoDouble(ACCOUNT_BALANCE);
	double risk_usd = balance * (InpRiskPerTradePercent / 100.0);
	// Approximate profit for 1 lot if price moves by stop distance
	double price = (g_tick.bid + g_tick.ask) * 0.5;
	double stop_price_move = stop_distance_points * g_point;
	double profit_1lot = 0.0;
	bool ok_profit = OrderCalcProfit(ORDER_TYPE_SELL, g_symbol, 1.0, price, price - stop_price_move, profit_1lot);
	// per point value for 1 lot
	double perLotPerPointUSD;
	if(ok_profit)
		perLotPerPointUSD = MathMax(MathAbs(profit_1lot) / MathMax(stop_distance_points, 1.0), 0.0000001);
	else
	{
		double tick_value = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_VALUE);
		double tick_size  = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_SIZE);
		// value per price point (point == g_point)
		perLotPerPointUSD = (tick_size > 0.0 ? tick_value * (g_point / tick_size) : 0.01);
		if(perLotPerPointUSD <= 0.0) perLotPerPointUSD = 0.01;
	}
	double lot = risk_usd / (perLotPerPointUSD * stop_distance_points);
	return(MathMax(NormalizeDouble(lot, 2), InpFixedLot));
}

bool EnsurePositionLimit()
{
	if(!InpOnePositionPerSymbol) return(true);
	if(PositionSelect(g_symbol)) return(false);
	return(true);
}

string UniqueId(const string prefix)
{
	ulong ms = GetMicrosecondCount();
	return(prefix + "_" + IntegerToString((long)TimeCurrent()) + "_" + IntegerToString((long)(ms % 1000000)));
}

void DrawEntryAndLevels(bool is_buy, double price, double sl, double tp)
{
	if(!InpVisualAnnotations) return;
	// Arrow
	string nameA = UniqueId(is_buy ? "BUY" : "SELL");
	int arrowType = is_buy ? OBJ_ARROW_UP : OBJ_ARROW_DOWN;
	ObjectCreate(0, nameA, arrowType, 0, iTime(g_symbol, InpTimeframe, 0), price);
	ObjectSetInteger(0, nameA, OBJPROP_COLOR, is_buy ? InpBuyColor : InpSellColor);
	ObjectSetInteger(0, nameA, OBJPROP_WIDTH, 2);
	// SL line
	string nameSL = UniqueId("SL");
	ObjectCreate(0, nameSL, OBJ_HLINE, 0, 0, sl);
	ObjectSetInteger(0, nameSL, OBJPROP_COLOR, InpSLColor);
	ObjectSetInteger(0, nameSL, OBJPROP_STYLE, STYLE_DASH);
	ObjectSetInteger(0, nameSL, OBJPROP_WIDTH, 1);
	// TP line
	string nameTP = UniqueId("TP");
	ObjectCreate(0, nameTP, OBJ_HLINE, 0, 0, tp);
	ObjectSetInteger(0, nameTP, OBJPROP_COLOR, InpTPColor);
	ObjectSetInteger(0, nameTP, OBJPROP_STYLE, STYLE_DOT);
	ObjectSetInteger(0, nameTP, OBJPROP_WIDTH, 1);
}

void DrawEntryRRLabel(bool is_buy, double entry_price, double sl, double tp)
{
	if(!InpVisualAnnotations || !InpShowRRLabel) return;
	double rr = 0.0;
	double risk = MathMax(MathAbs(entry_price - sl), 0.0000001);
	rr = MathAbs(tp - entry_price) / risk;
	string nameT = UniqueId("RR");
	ObjectCreate(0, nameT, OBJ_TEXT, 0, iTime(g_symbol, InpTimeframe, 0), entry_price + (is_buy ? risk*0.3 : -risk*0.3));
	ObjectSetString(0, nameT, OBJPROP_TEXT, StringFormat("RR=%.2f", rr));
	ObjectSetInteger(0, nameT, OBJPROP_COLOR, is_buy ? InpBuyColor : InpSellColor);
	ObjectSetInteger(0, nameT, OBJPROP_FONTSIZE, 9);
}

void DrawWicklessMarkers(const MqlRates &rates[], int bars, const double &ha_open[], const double &ha_close[], const double &ha_high[], const double &ha_low[])
{
	if(!InpVisualAnnotations || !InpShowWicklessMarkers) return;
	int maxk = MathMin(InpLookbackMaxBars, bars-1);
	for(int k=1; k<=maxk; ++k)
	{
		string name;
		datetime t = rates[k].time;
		double y = rates[k].close;
		bool bull = (ha_close[k] > ha_open[k]) && MathAbs(ha_low[k] - MathMin(ha_open[k], ha_close[k])) <= (g_point * 0.1);
		bool bear = (ha_close[k] < ha_open[k]) && MathAbs(ha_high[k] - MathMax(ha_open[k], ha_close[k])) <= (g_point * 0.1);
		if(bull)
		{
			name = StringFormat("WL_BULL_%I64d", (long long)t);
			if(ObjectFind(0, name) == -1)
			{
				ObjectCreate(0, name, OBJ_ARROW_UP, 0, t, y);
				ObjectSetInteger(0, name, OBJPROP_COLOR, InpWicklessBullColor);
				ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
			}
		}
		else if(bear)
		{
			name = StringFormat("WL_BEAR_%I64d", (long long)t);
			if(ObjectFind(0, name) == -1)
			{
				ObjectCreate(0, name, OBJ_ARROW_DOWN, 0, t, y);
				ObjectSetInteger(0, name, OBJPROP_COLOR, InpWicklessBearColor);
				ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
			}
		}
	}
}

void PlaceOrder(bool is_buy, double sl_price, double tp_price, const string comment)
{
	if(!EnsurePositionLimit()) return;
	double stop_distance_points = MathAbs(((is_buy ? (g_tick.bid - sl_price) : (sl_price - g_tick.ask))) / g_point);
	double lot = InpUseRiskSizing ? CalculateRiskLotByStopUSD(stop_distance_points) : InpFixedLot;
	Trade.SetExpertMagicNumber(InpMagic);
	Trade.SetDeviationInPoints((int)MathMax(g_spread_points * 2, 10));
	bool ok = false;
	if(is_buy) ok = Trade.Buy(lot, g_symbol, 0.0, sl_price, tp_price, comment);
	else ok = Trade.Sell(lot, g_symbol, 0.0, sl_price, tp_price, comment);
	if(!ok) Print("Order failed: ", _LastError);
	else 
	{
		double entry = is_buy ? g_tick.ask : g_tick.bid;
		DrawEntryAndLevels(is_buy, entry, sl_price, tp_price);
		DrawEntryRRLabel(is_buy, entry, sl_price, tp_price);
	}
}

void ManageOpenPosition()
{
	if(!PositionSelect(g_symbol)) return;
	double atr[]; if(!ComputeATR(g_symbol, InpTimeframe, InpATRPeriod, 100, atr)) return;
	double curr_atr = atr[0];
	long type = PositionGetInteger(POSITION_TYPE);
	double vol  = PositionGetDouble(POSITION_VOLUME);
	double price_open = PositionGetDouble(POSITION_PRICE_OPEN);
	double sl   = PositionGetDouble(POSITION_SL);
	double tp   = PositionGetDouble(POSITION_TP);
	bool is_buy = (type == POSITION_TYPE_BUY);
	if(InpEnablePartialTP && vol > SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN))
	{
		double r_distance = MathAbs(price_open - sl);
		if(r_distance > 0.0)
		{
			double target_price = is_buy ? (price_open + r_distance) : (price_open - r_distance);
			bool reached = is_buy ? (g_tick.bid >= target_price) : (g_tick.ask <= target_price);
			if(reached)
			{
				double new_vol = MathMax(SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN), NormalizeDouble(vol * 0.5, 2));
				if(new_vol < vol)
				{
					Trade.PositionClosePartial(g_symbol, vol - new_vol);
				}
				if(InpEnableTrailingAfterPTP)
				{
					double new_sl = is_buy ? MathMax(sl, g_tick.bid - curr_atr * InpATRMultiplier) : MathMin(sl, g_tick.ask + curr_atr * InpATRMultiplier);
					Trade.PositionModify(g_symbol, new_sl, tp);
				}
			}
		}
	}
	if(InpEnableTrailingAfterPTP)
	{
		double trail_sl = is_buy ? (g_tick.bid - curr_atr * InpATRMultiplier) : (g_tick.ask + curr_atr * InpATRMultiplier);
		if(is_buy && trail_sl > sl) Trade.PositionModify(g_symbol, trail_sl, tp);
		else if(!is_buy && trail_sl < sl) Trade.PositionModify(g_symbol, trail_sl, tp);
	}
}

void EvaluateAndTrade()
{
	const int need_bars = MathMax(200, InpLookbackMaxBars + InpATRPeriod + 10);
	MqlRates rates[]; int bars = CopyRatesSafe(g_symbol, InpTimeframe, need_bars, rates);
	if(bars < need_bars) return;
	double ha_o[], ha_c[], ha_h[], ha_l[];
	if(!ComputeHeikinAshi(rates, bars, ha_o, ha_c, ha_h, ha_l)) return;
	double atr[]; if(!ComputeATR(g_symbol, InpTimeframe, InpATRPeriod, bars, atr)) return;
	double vwap[]; if(!ComputeVWAP(rates, bars, vwap)) return;

	bool doji = false;
	int prev1 = 1, prev2 = 2;
	doji = IsDoji(0, rates, ha_o, ha_c, prev1, prev2);

	bool buy_trend = VWAPFilterIsBuy(vwap);
	bool sell_trend = VWAPFilterIsSell(vwap);
	bool has_bearish_run = HasConsecutiveWicklessRun(true, InpLookbackMaxBars, ha_o, ha_c, ha_h, ha_l);
	bool has_bullish_run = HasConsecutiveWicklessRun(false, InpLookbackMaxBars, ha_o, ha_c, ha_h, ha_l);

	// update debug state for on-chart display
	g_dbgDoji = doji;
	g_dbgBuyTrend = buy_trend;
	g_dbgSellTrend = sell_trend;
	g_dbgHasBearishRun = has_bearish_run;
	g_dbgHasBullishRun = has_bullish_run;
	g_dbgVWAP = vwap[0];

	// draw wickless markers for lookback window
	DrawWicklessMarkers(rates, bars, ha_o, ha_c, ha_h, ha_l);

	if(doji)
	{
		// BUY
		if(buy_trend && has_bearish_run)
		{
			if(rates[0].time != g_lastBuySignalBarTime)
			{
				double curr_atr = atr[0];
				double sl = rates[0].low - curr_atr * InpATRMultiplier;
				double risk = MathAbs(g_tick.ask - sl);
				double tp = g_tick.ask + risk; // 1R
				PlaceOrder(true, sl, tp, "VWAP-HA-Doji Buy");
				g_lastBuySignalBarTime = rates[0].time;
			}
		}
		// SELL
		if(sell_trend && has_bullish_run)
		{
			if(rates[0].time != g_lastSellSignalBarTime)
			{
				double curr_atr = atr[0];
				double sl = rates[0].high + curr_atr * InpATRMultiplier;
				double risk = MathAbs(sl - g_tick.bid);
				double tp = g_tick.bid - risk; // 1R
				PlaceOrder(false, sl, tp, "VWAP-HA-Doji Sell");
				g_lastSellSignalBarTime = rates[0].time;
			}
		}
	}
}

//============================ EA Events ============================//
int OnInit()
{
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

	// On-chart status panel
	if(InpVisualAnnotations)
	{
		string label = "EA_STATUS_PANEL";
		if(ObjectFind(0, label) == -1)
		{
			ObjectCreate(0, label, OBJ_LABEL, 0, 0, 0);
			ObjectSetInteger(0, label, OBJPROP_CORNER, CORNER_LEFT_UPPER);
			ObjectSetInteger(0, label, OBJPROP_XDISTANCE, 10);
			ObjectSetInteger(0, label, OBJPROP_YDISTANCE, 20);
		}
		string txt;
		txt = StringFormat("%s %s\nVWAP: %.2f\nDoji: %s\nTrend: %s\nWicklessRun(Bear): %s\nWicklessRun(Bull): %s", 
			g_symbol, EnumToString(InpTimeframe), g_dbgVWAP, g_dbgDoji ? "Yes" : "No",
			g_dbgBuyTrend ? "Buy-only" : (g_dbgSellTrend ? "Sell-only" : "Neutral"),
			g_dbgHasBearishRun ? "Yes" : "No",
			g_dbgHasBullishRun ? "Yes" : "No");
		ObjectSetString(0, label, OBJPROP_TEXT, txt);
		ObjectSetInteger(0, label, OBJPROP_COLOR, clrWhite);
		ObjectSetInteger(0, label, OBJPROP_FONTSIZE, 10);
	}
}

void OnDeinit(const int reason)
{
	// No-op
}