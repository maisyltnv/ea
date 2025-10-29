#property copyright "User"
#property link      ""
#property version   "1.00"
#property strict

//======================== Inputs ========================
input string Inp___General________________________ = "------ General ------";
input long   InpMagicNumber                       = 91516001;
input string InpOrderComment                      = "EMA Pullback SwingLow Buy";
input double InpLot1                              = 0.01;   // First Buy Limit lot
input double InpLot2                              = 0.02;   // Second Buy Limit lot
input double InpLot3                              = 0.03;   // Third Buy Limit lot
input int    InpMaxSpreadPoints                   = 80;     // Max allowed spread in points

input string Inp___Strategy_______________________ = "------ Strategy ------";
input ENUM_TIMEFRAMES InpTF_M1                    = PERIOD_M1;  // M1 timeframe
input ENUM_TIMEFRAMES InpTF_M5                    = PERIOD_M5;  // M5 timeframe
input int    InpEMA_Fast                          = 14;
input int    InpEMA_Mid1                          = 26;
input int    InpEMA_Mid2                          = 50;
input int    InpEMA_Mid3                          = 100;
input int    InpEMA_Slow                          = 200;
input int    InpEntryOffsetPoints                 = 300;    // Entry: below swing low by X points
input int    InpGridStepPoints                    = 300;    // Distance between pending orders (points)
input int    InpSLPoints                          = 1000;   // Stop Loss (points)
input int    InpTPPoints                          = 1000;   // Take Profit (points)
input int    InpSwingLeftRight                    = 3;      // Swing low detection: bars left/right
input int    InpLookbackBars                      = 50;     // Max bars to search for swing low

//======================== Globals ========================
string g_symbol;
double g_point;
int    g_digits;

//======================== Utilities ========================
bool IsSpreadOk()
{
	int spread_points = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
	return spread_points <= InpMaxSpreadPoints;
}

int CountOurOrders()
{
	int total = 0;
	// Pending orders (compatible approach)
    for(int i=0; i<OrdersTotal(); ++i)
    {
        ulong ticket = OrderGetTicket(i);
        if(ticket==0) continue;
        if(!OrderSelect(ticket)) continue;

        string ord_symbol = "";
        OrderGetString(ORDER_SYMBOL, ord_symbol);
        if(ord_symbol != _Symbol) continue;

        long ord_magic = 0;
        OrderGetInteger(ORDER_MAGIC, ord_magic);
        if(ord_magic != (long)InpMagicNumber) continue;
        ++total;
    }
	// Open positions
	for(int j=0; j<PositionsTotal(); ++j)
	{
		string pos_symbol = PositionGetSymbol(j);
		if(pos_symbol != _Symbol) continue;
		if(!PositionSelect(pos_symbol)) continue;

		long pos_magic = 0;
		PositionGetInteger(POSITION_MAGIC, pos_magic);
		if(pos_magic != (long)InpMagicNumber) continue;
		++total;
	}
	return total;
}

double GetEMA(ENUM_TIMEFRAMES tf, int period, int shift)
{
	double result = EMPTY_VALUE;
	double buffer[];
	int handle = iMA(_Symbol, tf, period, 0, MODE_EMA, PRICE_CLOSE);
	if(handle != INVALID_HANDLE)
	{
		int copied = CopyBuffer(handle, 0, shift, 1, buffer);
		if(copied == 1)
			result = buffer[0];
		IndicatorRelease(handle);
	}
	return result;
}

bool EmasAlignedPullback(ENUM_TIMEFRAMES tf)
{
	// Use last closed bar (shift=1) for stability
	double e14 = GetEMA(tf, InpEMA_Fast, 1);
	double e26 = GetEMA(tf, InpEMA_Mid1, 1);
	double e50 = GetEMA(tf, InpEMA_Mid2, 1);
	double e100 = GetEMA(tf, InpEMA_Mid3, 1);
	double e200 = GetEMA(tf, InpEMA_Slow, 1);
	if(e14==EMPTY_VALUE || e26==EMPTY_VALUE || e50==EMPTY_VALUE || e100==EMPTY_VALUE || e200==EMPTY_VALUE) return false;

	bool aligned = (e14 > e26 && e26 > e50 && e50 > e100 && e100 > e200);
	if(!aligned) return false;

	// Pullback definition: last closed price below fast EMA but above slow EMA200
	double close1 = iClose(_Symbol, tf, 1);
	if(close1 == 0.0) return false;
	bool pullback = (close1 < e14 && close1 > e200);
	return pullback;
}

bool FindRecentSwingLow(double &swingLowPrice)
{
	// Swing low: Low[k] is the minimum and strictly lower than its neighbors within left/right window
	int leftRight = MathMax(1, InpSwingLeftRight);
	int maxBars = MathMax(10, InpLookbackBars);
	int start = 2; // avoid current forming bar and the last closed bar for safety
	int endBar = MathMin(Bars(_Symbol, InpTF_M1), maxBars + start);
	if(endBar <= start + leftRight*2) return false;

	double bestLow = DBL_MAX;
	bool found = false;
	for(int i=start; i<endBar; ++i)
	{
		double candidate = iLow(_Symbol, InpTF_M1, i);
		bool isSwing = true;
		for(int l=1; l<=leftRight; ++l)
		{
			if(iLow(_Symbol, InpTF_M1, i-l) <= candidate || iLow(_Symbol, InpTF_M1, i+l) <= candidate)
			{
				isSwing = false;
				break;
			}
		}
		if(isSwing)
		{
			if(candidate < bestLow)
			{
				bestLow = candidate;
				found = true;
			}
		}
	}
	if(!found) return false;
	swingLowPrice = bestLow;
	return true;
}

double NormalizePrice(double price)
{
	return NormalizeDouble(price, g_digits);
}

bool PlaceBuyLimit(double price, double lot, double sl_price, double tp_price)
{
	MqlTradeRequest req;
	MqlTradeResult  res;
	ZeroMemory(req);
	ZeroMemory(res);

	req.action   = TRADE_ACTION_PENDING;
	req.type     = ORDER_TYPE_BUY_LIMIT;
	req.symbol   = _Symbol;
	req.volume   = lot;
	req.price    = NormalizePrice(price);
    req.sl       = NormalizePrice(sl_price);
    req.tp       = NormalizePrice(tp_price);
	req.deviation= 20;
	req.magic    = InpMagicNumber;
	req.type_filling = ORDER_FILLING_RETURN;
	req.type_time    = ORDER_TIME_GTC;
	req.comment      = InpOrderComment;

	bool ok = OrderSend(req, res);
	return ok && (res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_PLACED);
}

void TryPlaceSetup()
{
	if(!IsSpreadOk()) return;
    // Require M5 alignment+pullback and M1 alignment+pullback
	if(!EmasAlignedPullback(InpTF_M5)) return;
	if(!EmasAlignedPullback(InpTF_M1)) return;

	// Only one active order/position set at a time
	if(CountOurOrders() > 0) return;

	double swingLow;
	if(!FindRecentSwingLow(swingLow)) return;

	// Entry price 300 points below swing low
	double entry1 = swingLow - InpEntryOffsetPoints * g_point;
	// Ensure entry is below current Bid (buy limit must be below market)
	double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
	if(!(entry1 < bid - 2*g_point)) return;

	double entry2 = entry1 - InpGridStepPoints * g_point;
	double entry3 = entry2 - InpGridStepPoints * g_point;

    // Shared SL/TP for all orders, based on first entry
    double shared_sl = entry1 - InpSLPoints * g_point;
    double shared_tp = entry1 + InpTPPoints * g_point;

    bool ok1 = PlaceBuyLimit(entry1, InpLot1, shared_sl, shared_tp);
    bool ok2 = PlaceBuyLimit(entry2, InpLot2, shared_sl, shared_tp);
    bool ok3 = PlaceBuyLimit(entry3, InpLot3, shared_sl, shared_tp);
	// No further handling here; orders share identical SL/TP distances from their own entry
}

//======================== Standard Events ========================
int OnInit()
{
	g_symbol = _Symbol;
	g_point  = _Point;
	g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
	return(INIT_SUCCEEDED);
}

void OnTick()
{
	// Only operate on the chart symbol
	if(_Symbol != g_symbol) return;
	// Work only on new M1 bar to avoid spamming
	static datetime lastBarTime = 0;
	datetime curBar = iTime(_Symbol, InpTF_M1, 0);
	if(curBar == lastBarTime) return;
	lastBarTime = curBar;

	TryPlaceSetup();
}

void OnDeinit(const int reason)
{
}


