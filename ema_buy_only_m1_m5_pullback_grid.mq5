#property copyright "User"
#property link      ""
#property version   "1.00"
#property strict

//======================== Inputs ========================
input string Inp___General________________________ = "------ General ------";
input long   InpMagicNumber                       = 91526001;
input string InpOrderComment                      = "EMA M1/M5 Pullback Buy Grid";
input double InpLot                               = 0.01;   // Market order lot
input double InpLot2                              = 0.02;   // Buy Limit 1 lot
input double InpLot3                              = 0.03;   // Buy Limit 2 lot
input double InpLot4                              = 0.04;   // Buy Limit 3 lot
input int    InpMaxSpreadPoints                   = 120;    // Max allowed spread in points

input string Inp___Strategy_______________________ = "------ Strategy ------";
input ENUM_TIMEFRAMES InpTF_M1                    = PERIOD_M1;  // M1 timeframe
input ENUM_TIMEFRAMES InpTF_M5                    = PERIOD_M5;  // M5 timeframe
input int    InpEMA_Fast                          = 14;
input int    InpEMA_Mid1                          = 26;
input int    InpEMA_Mid2                          = 50;
input int    InpEMA_Mid3                          = 100;
input int    InpEMA_Slow                          = 200;

input int    InpSLPoints                          = 1000;   // Stop Loss (points) from first entry
input int    InpTPPoints                          = 1000;   // Take Profit (points) from first entry
input int    InpGridStepPoints                    = 2;      // Distance between pending orders (points)
input int    InpNumPending                        = 3;       // Number of buy limit pendings
input int    InpCloseAllProfitOffsetPoints        = 100;    // Case3 threshold above first entry
input int    InpCase4SumPoints                    = 1000;   // Case4: min sum of first 3 positions' profit (points)

//======================== Globals ========================
string g_symbol;
double g_point;
int    g_digits;
bool   g_basketActive = false;
double g_sharedSL = 0.0;
double g_sharedTP = 0.0;
double g_firstEntry = 0.0;

//======================== Utilities ========================
bool IsSpreadOk()
{
	int spread_points = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
	return spread_points <= InpMaxSpreadPoints;
}

void DeleteOurPendingOrders()
{
    int maxAttempts = 10; // Prevent infinite loop
    int attempts = 0;
    
    while(attempts < maxAttempts)
    {
        bool foundOrder = false;
        for(int i=OrdersTotal()-1; i>=0; --i)
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

            ENUM_ORDER_TYPE t = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
            if(t==ORDER_TYPE_BUY_LIMIT || t==ORDER_TYPE_SELL_LIMIT || t==ORDER_TYPE_BUY_STOP || t==ORDER_TYPE_SELL_STOP || t==ORDER_TYPE_BUY_STOP_LIMIT || t==ORDER_TYPE_SELL_STOP_LIMIT)
            {
                foundOrder = true;
                MqlTradeRequest req; MqlTradeResult res; ZeroMemory(req); ZeroMemory(res);
                req.action = TRADE_ACTION_REMOVE;
                req.order  = ticket;
                req.symbol = _Symbol;
                req.magic  = InpMagicNumber;
                
                if(OrderSend(req, res))
                {
                    Print("Successfully removed pending order #", ticket);
                }
                else
                {
                    Print("Failed to remove pending order #", ticket, " Error: ", res.retcode, " - ", res.comment);
                }
                break; // Exit inner loop and try again
            }
        }
        
        if(!foundOrder) break; // No more orders to remove
        attempts++;
        Sleep(100); // Small delay between attempts
    }
    
    if(attempts >= maxAttempts)
    {
        Print("Warning: Could not remove all pending orders after ", maxAttempts, " attempts");
    }
}

void CloseOurOpenPositions()
{
    for(int j=PositionsTotal()-1; j>=0; --j)
    {
        string pos_symbol = PositionGetSymbol(j);
        if(pos_symbol != _Symbol) continue;
        if(!PositionSelect(pos_symbol)) continue;

        long pos_magic = 0;
        PositionGetInteger(POSITION_MAGIC, pos_magic);
        if(pos_magic != (long)InpMagicNumber) continue;

        long type = PositionGetInteger(POSITION_TYPE);
        double volume = PositionGetDouble(POSITION_VOLUME);
        ulong pos_ticket = (ulong)PositionGetInteger(POSITION_TICKET);

        MqlTradeRequest req; MqlTradeResult res; ZeroMemory(req); ZeroMemory(res);
        req.action = TRADE_ACTION_DEAL;
        req.symbol = _Symbol;
        req.magic  = InpMagicNumber;
        req.deviation = 20;
        if(type==POSITION_TYPE_BUY)
        {
            req.type = ORDER_TYPE_SELL;
            req.volume = volume;
            req.price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        }
        else if(type==POSITION_TYPE_SELL)
        {
            req.type = ORDER_TYPE_BUY;
            req.volume = volume;
            req.price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        }
        req.position = pos_ticket; // close specific position
        req.type_filling = ORDER_FILLING_IOC;
        if(req.volume>0.0)
        {
            bool sent = OrderSend(req, res);
        }
    }
}

void VerifyCleanup()
{
    // Check for any remaining pending orders
    int remainingOrders = 0;
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

        ENUM_ORDER_TYPE t = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
        if(t==ORDER_TYPE_BUY_LIMIT || t==ORDER_TYPE_SELL_LIMIT || t==ORDER_TYPE_BUY_STOP || t==ORDER_TYPE_SELL_STOP || t==ORDER_TYPE_BUY_STOP_LIMIT || t==ORDER_TYPE_SELL_STOP_LIMIT)
        {
            remainingOrders++;
            Print("Warning: Pending order #", ticket, " still exists after cleanup attempt");
        }
    }
    
    if(remainingOrders == 0)
    {
        Print("Cleanup successful: All pending orders removed");
    }
    else
    {
        Print("Cleanup incomplete: ", remainingOrders, " pending orders remain");
    }
}

int CountOurOrders()
{
	int total = 0;
	// Pending orders
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

bool M1Trigger()
{
    // Use current bar values cautiously; require last closed for EMAs, current price > ema14
    double e14 = GetEMA(InpTF_M1, InpEMA_Fast, 1);
    double e26 = GetEMA(InpTF_M1, InpEMA_Mid1, 1);
    double e50 = GetEMA(InpTF_M1, InpEMA_Mid2, 1);
    double e100= GetEMA(InpTF_M1, InpEMA_Mid3, 1);
    double e200= GetEMA(InpTF_M1, InpEMA_Slow, 1);
    if(e14==EMPTY_VALUE || e26==EMPTY_VALUE || e50==EMPTY_VALUE || e100==EMPTY_VALUE || e200==EMPTY_VALUE) return false;

    bool aligned = (e14 > e26 && e26 > e50 && e50 > e100 && e100 > e200);
    if(!aligned) return false;

    double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    return (price > e14);
}

double NormalizePrice(double price)
{
    return NormalizeDouble(price, g_digits);
}

bool PlaceBuyLimit(double price, double lot, double sl_price, double tp_price)
{
    MqlTradeRequest req; MqlTradeResult  res; ZeroMemory(req); ZeroMemory(res);
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

bool PlaceMarketBuy(double &filled_price)
{
    MqlTradeRequest req; MqlTradeResult res; ZeroMemory(req); ZeroMemory(res);
    req.action   = TRADE_ACTION_DEAL;
    req.symbol   = _Symbol;
    req.volume   = InpLot;
    req.type     = ORDER_TYPE_BUY;
    req.price    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    req.deviation= 20;
    req.magic    = InpMagicNumber;
    req.type_filling = ORDER_FILLING_FOK;
    req.comment  = InpOrderComment;
    bool sent = OrderSend(req, res);
    if(!sent || (res.retcode != TRADE_RETCODE_DONE && res.retcode != TRADE_RETCODE_PLACED))
        return false;
    // Query actual open price
    if(PositionSelect(_Symbol) && PositionGetInteger(POSITION_MAGIC)==InpMagicNumber)
        filled_price = PositionGetDouble(POSITION_PRICE_OPEN);
    else
        filled_price = req.price; // fallback
    return true;
}

void TryTriggerSetup()
{
    if(!IsSpreadOk()) return;
    // Require only M1 trigger per spec
    if(!M1Trigger()) return;

    // Only arm a new basket if nothing is active
    if(CountOurOrders() > 0) return;

    double first_fill = 0.0;
    if(!PlaceMarketBuy(first_fill)) return;

    // Shared SL/TP based on the first entry (as per example)
    g_firstEntry = first_fill;
    g_sharedSL = NormalizePrice(first_fill - InpSLPoints * g_point);
    g_sharedTP = NormalizePrice(first_fill + InpTPPoints * g_point);

    // Apply SL/TP to the just-opened position
    if(PositionSelect(_Symbol) && PositionGetInteger(POSITION_MAGIC)==InpMagicNumber)
    {
        ulong pos_ticket = (ulong)PositionGetInteger(POSITION_TICKET);
        MqlTradeRequest m; MqlTradeResult r; ZeroMemory(m); ZeroMemory(r);
        m.action   = TRADE_ACTION_SLTP;
        m.position = pos_ticket;
        m.sl       = g_sharedSL;
        m.tp       = g_sharedTP;
        OrderSend(m, r);
    }

    // Place N buy limits below first entry
    for(int n=1; n<=InpNumPending; ++n)
    {
        double entry = first_fill - (InpGridStepPoints * n) * g_point;
        double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        // ensure limit below market
        if(entry < bid - 2*g_point)
        {
            double lot = InpLot;
            if(n==1) lot = InpLot2; else if(n==2) lot = InpLot3; else if(n==3) lot = InpLot4;
            PlaceBuyLimit(entry, lot, g_sharedSL, g_sharedTP);
        }
    }

    g_basketActive = true;
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
    if(_Symbol != g_symbol) return;

    // Basket management
    if(g_basketActive)
    {
        double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        
        // Count open positions first
        int openPositions = 0;
        for(int j=0; j<PositionsTotal(); ++j)
        {
            string s = PositionGetSymbol(j);
            if(s != _Symbol) continue;
            if(!PositionSelect(s)) continue;
            long pm = 0; PositionGetInteger(POSITION_MAGIC, pm);
            if(pm != (long)InpMagicNumber) continue;
            ++openPositions;
        }
        
        // Case 1: price <= shared SL
        if(bid <= g_sharedSL)
        {
            Print("Case 1 triggered: SL hit, cleaning up...");
            DeleteOurPendingOrders();
            if(CountOurOrders() > 0) DeleteOurPendingOrders();
            CloseOurOpenPositions();
            VerifyCleanup();
            g_basketActive = false;
            return;
        }
        
        // Case 2: price >= shared TP
        if(bid >= g_sharedTP)
        {
            Print("Case 2 triggered: TP hit, cleaning up...");
            DeleteOurPendingOrders();
            if(CountOurOrders() > 0) DeleteOurPendingOrders();
            CloseOurOpenPositions();
            VerifyCleanup();
            g_basketActive = false;
            return;
        }
        
        // Case 3: if open positions >= 2 and price >= first-entry + offset (default 100)
        if(openPositions >= 2)
        {
            double trigger = g_firstEntry + InpCloseAllProfitOffsetPoints * g_point;
            if(bid >= trigger)
            {
                Print("Case 3 triggered: ", openPositions, " positions, price ", bid, " >= trigger ", trigger, ", cleaning up...");
                DeleteOurPendingOrders();
                if(CountOurOrders() > 0) DeleteOurPendingOrders();
                CloseOurOpenPositions();
                VerifyCleanup();
                g_basketActive = false;
                return;
            }
        }

        // Case 4: if open positions >= 3 and sum of first three positions' profit >= threshold points
        if(openPositions >= 3)
        {
            // Track first three positions by open time
            datetime t1 = LONG_MAX, t2 = LONG_MAX, t3 = LONG_MAX;
            double p1 = 0.0, p2 = 0.0, p3 = 0.0;
            double bidNow = bid;
            for(int k=0; k<PositionsTotal(); ++k)
            {
                string sy = PositionGetSymbol(k);
                if(sy != _Symbol) continue;
                if(!PositionSelect(sy)) continue;
                long pm2 = 0; PositionGetInteger(POSITION_MAGIC, pm2);
                if(pm2 != (long)InpMagicNumber) continue;

                datetime ot = (datetime)PositionGetInteger(POSITION_TIME);
                double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
                long ptype = PositionGetInteger(POSITION_TYPE);

                // compute profit in points per position (buy only in this EA)
                double pts = 0.0;
                if(ptype == POSITION_TYPE_BUY)
                    pts = (bidNow - openPrice) / g_point;
                else
                    pts = (openPrice - SymbolInfoDouble(_Symbol, SYMBOL_ASK)) / g_point; // safety

                // keep earliest three
                if(ot < t1)
                {
                    // shift down
                    t3 = t2; p3 = p2;
                    t2 = t1; p2 = p1;
                    t1 = ot; p1 = pts;
                }
                else if(ot < t2)
                {
                    t3 = t2; p3 = p2;
                    t2 = ot; p2 = pts;
                }
                else if(ot < t3)
                {
                    t3 = ot; p3 = pts;
                }
            }
            // sum only if we actually found three entries
            if(t3 != LONG_MAX)
            {
                double sumPts = p1 + p2 + p3;
                if(sumPts >= (double)InpCase4SumPoints)
                {
                    Print("Case 4 triggered: ", openPositions, " positions, sum profit ", sumPts, " >= ", InpCase4SumPoints, " points, cleaning up...");
                    DeleteOurPendingOrders();
                    if(CountOurOrders() > 0) DeleteOurPendingOrders();
                    CloseOurOpenPositions();
                    VerifyCleanup();
                    g_basketActive = false;
                    return;
                }
            }
        }
    }

    // Check once per new M1 bar
    static datetime lastBarTime = 0;
    datetime curBar = iTime(_Symbol, InpTF_M1, 0);
    if(curBar == lastBarTime) return;
    lastBarTime = curBar;

    if(CountOurOrders() == 0)
    {
        TryTriggerSetup();
        return;
    }

    // no re-arming while active
}

void OnDeinit(const int reason)
{
}


