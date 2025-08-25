#property copyright   "GPT-5"
#property link        "https://"
#property version     "1.0"
#property description "ETHUSD M1 VWAP+HA+Doji with ATR SL/TP, sessions, risk"
#property strict

#include <Trade/Trade.mqh>

input string   InpSymbol                  = "ETHUSD";
input ENUM_TIMEFRAMES InpTimeframe        = PERIOD_M1;

input int      InpSessionsTzOffsetHours   = 2;
input bool     InpEnableLondonSession     = true;
input int      InpLondonStartHour         = 7;
input int      InpLondonEndHour           = 16;
input bool     InpEnableNewYorkSession    = true;
input int      InpNewYorkStartHour        = 13;
input int      InpNewYorkEndHour          = 22;

input bool     InpUseRiskSizing           = true;
input double   InpRiskPerTradePercent     = 0.3;
input double   InpFixedLot                = 0.01;
input double   InpMaxDailyDrawdownUSD     = 100.0;

input int      InpATRPeriod               = 14;
input double   InpATRMultiplier           = 1.5;
input int      InpLookbackMaxBars         = 10;
input double   InpDojiMaxBodyPctOfRange   = 10.0;
input bool     InpRequireDojiBodyGreaterPrevWickless = true;

input bool     InpEnablePartialTP         = true;
input bool     InpEnableTrailingAfterPTP  = true;

input bool     InpEnableNewsFilter        = false; // disabled - stubbed
input int      InpNewsCloseMinsBefore     = 10;

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

bool IsWithinSessions(datetime t_server)
{
	datetime t_gmt = TimeGMT();
	int tz = InpSessionsTzOffsetHours;
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
	double realized = 0.0;
	int total = (int)HistoryDealsTotal();
	for(uint i=0; i<(uint)total; ++i)
	{
		ulong ticket = HistoryDealGetTicket(i);
		if(ticket == 0) continue;
		long reason = (long)HistoryDealGetInteger(ticket, DEAL_REASON);
		if(reason != DEAL_REASON_SL && reason != DEAL_REASON_TP && reason != DEAL_REASON_CLOSE && reason != DEAL_REASON_MARGINCALL && reason != DEAL_REASON_CLIENT)
			continue;
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
	return(false);
}

void CloseAllPositionsBeforeNews()
{
	if(!InpEnableNewsFilter) return;
	if(!HasHighImpactNewsWithinMinutes(InpNewsCloseMinsBefore)) return;
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

bool ComputeHeikinAshi(const MqlRates &rates[], int count, double &ha_open[], double &ha_close[], double &ha_high[], double &ha_low[])
{
	if(count <= 0) return(false);
	ArraySetAsSeries(ha_open,  true);
	ArraySetAsSeries(ha_close, true);
	ArraySetAsSeries(ha_high,  true);
	ArraySetAsSeries(ha_low,   true);
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

bool ComputeVWAP(const MqlRates &rates[], int count, double &vwap[])
{
	ArraySetAsSeries(vwap, true);
	if(count <= 0) return(false);
	int tz = InpSessionsTzOffsetHours;
	double cumulative_pv = 0.0;
	double cumulative_v  = 0.0;
	MqlDateTime d;
	int current_day_yday = -1;
	for(int i=count-1; i>=0; --i)
	{
		datetime t_gmt = rates[i].time - (TimeCurrent() - TimeGMT());
		datetime t_session = t_gmt + tz * 3600;
		TimeToStruct(t_session, d);
		int yday = d.day + d.mon*32 + d.year*500;
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

bool IsBullishHA(int i, const double &ha_open[], const double &ha_close[]){ return(ha_close[i] > ha_open[i]); }
bool IsBearishHA(int i, const double &ha_open[], const double &ha_close[]){ return(ha_close[i] < ha_open[i]); }

bool IsBullishWicklessHA(int i, const double &ha_open[], const double &ha_close[], const double &ha_low[])
{
	double low_pivot = MathMin(ha_open[i], ha_close[i]);
	return(IsBullishHA(i, ha_open, ha_close) && MathAbs(ha_low[i] - low_pivot) <= (g_point * 0.1));
}

bool IsBearishWicklessHA(int i, const double &ha_open[], const double &ha_close[], const double &ha_high[])
{
	double high_pivot = MathMax(ha_open[i], ha_close[i]);
	return(IsBearishHA(i, ha_open, ha_close) && MathAbs(ha_high[i] - high_pivot) <= (g_point * 0.1));
}

bool HasConsecutiveWicklessRun(bool bearish, int lookback, const double &ha_open[], const double &ha_close[], const double &ha_high[], const double &ha_low[])
{
	int found_run = 0;
	for(int i=1; i<=lookback; ++i)
	{
		bool ok = bearish ? IsBearishWicklessHA(i, ha_open, ha_close, ha_high) : IsBullishWicklessHA(i, ha_open, ha_close, ha_low);
		if(ok)
		{
			found_run++;
			if(found_run >= 2) return(true);
		}
		else
		{
			bool opposite = bearish ? IsBullishHA(i, ha_open, ha_close) : IsBearishHA(i, ha_open, ha_close);
			if(opposite) found_run = 0; else found_run = 0;
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

bool VWAPFilterIsBuy(const double &vwap[]){ return(g_tick.ask > vwap[0]); }
bool VWAPFilterIsSell(const double &vwap[]){ return(g_tick.bid < vwap[0]); }

double CalculateRiskLotByStopUSD(double stop_distance_points)
{
	if(stop_distance_points <= 0.0) return(InpFixedLot);
	double balance = AccountInfoDouble(ACCOUNT_BALANCE);
	double risk_usd = balance * (InpRiskPerTradePercent / 100.0);
	double price = (g_tick.bid + g_tick.ask) * 0.5;
	double stop_price_move = stop_distance_points * g_point;
	double profit_1lot = 0.0;
	bool ok_profit = OrderCalcProfit(ORDER_TYPE_SELL, g_symbol, 1.0, price, price - stop_price_move, profit_1lot);
	double perLotPerPointUSD;
	if(ok_profit)
		perLotPerPointUSD = MathMax(MathAbs(profit_1lot) / MathMax(stop_distance_points, 1.0), 0.0000001);
	else
	{
		double tick_value = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_VALUE);
		double tick_size  = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_SIZE);
		perLotPerPointUSD = (tick_size > 0.0 ? tick_value * (g_point / tick_size) : 0.01);
	}
	double lot = risk_usd / (perLotPerPointUSD * stop_distance_points);
	return(MathMax(NormalizeDouble(lot, 2), InpFixedLot));
}

bool EnsurePositionLimit(){ if(!InpOnePositionPerSymbol) return(true); if(PositionSelect(g_symbol)) return(false); return(true);} 

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

	if(doji)
	{
		if(buy_trend && has_bearish_run)
		{
			if(rates[0].time != g_lastBuySignalBarTime)
			{
				double curr_atr = atr[0];
				double sl = rates[0].low - curr_atr * InpATRMultiplier;
				double risk = MathAbs(g_tick.ask - sl);
				double tp = g_tick.ask + risk;
				PlaceOrder(true, sl, tp, "VWAP-HA-Doji Buy");
				g_lastBuySignalBarTime = rates[0].time;
			}
		}
		if(sell_trend && has_bullish_run)
		{
			if(rates[0].time != g_lastSellSignalBarTime)
			{
				double curr_atr = atr[0];
				double sl = rates[0].high + curr_atr * InpATRMultiplier;
				double risk = MathAbs(sl - g_tick.bid);
				double tp = g_tick.bid - risk;
				PlaceOrder(false, sl, tp, "VWAP-HA-Doji Sell");
				g_lastSellSignalBarTime = rates[0].time;
			}
		}
	}
}

int OnInit(){ if(!GetSymbolProps(InpSymbol)) return(INIT_FAILED); Trade.SetExpertMagicNumber(InpMagic); return(INIT_SUCCEEDED);} 

void OnTick()
{
	if(!GetSymbolProps(InpSymbol)) return;
	if(DailyDrawdownExceeded()) return;
	if(!IsWithinSessions(TimeCurrent())) return;
	CloseAllPositionsBeforeNews();
	ManageOpenPosition();
	EvaluateAndTrade();
}

void OnDeinit(const int reason){}